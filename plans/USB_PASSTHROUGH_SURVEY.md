# USB 透傳在 protected VM 下要什麼機制（2026-09-04 調查）

問題：virtio-gpu 為了讓 host GPU 摸得到 guest 記憶體，開了池子（`gfx_host` / `drm2kgsl_host` /
`venus_host`，boot 時 SHARE 的 region）並把配置全搬進去。USB 透傳也要這樣嗎？純靠 swiotlb
夠不夠？還是要把 USB 控制器的 SMMU/stage-2 空間掛進 guest？

## 結論先講

**純 swiotlb（`restricted-dma-pool`）就夠。不需要池，也不需要（也不可能）掛 USB 控制器的 MMU
空間。** 而且 host 端與 guest 端的機制**現在就已經全部到位**，protected VM 裡之所以沒有 USB，
是 crosvm 上游一行 gate 把它關掉了：

```rust
// src/crosvm/cmdline.rs:3859-3864（上游原碼，fork 沒動）
if !matches!(cfg.protection_type, ProtectionType::Unprotected) {
    // USB devices only work for unprotected VMs.
    cfg.usb = false;
    cfg.rng = false;
}
```

三個理由，每個都對到碼或實機：

1. **crosvm 的 xHCI 是 userspace 全模擬，host 端真正的 USB DMA 不碰 guest 記憶體。**
   guest 看到的是一顆 PCI xHCI（一個 64 KiB MMIO BAR，沒有共享記憶體 BAR）；crosvm 讀 TRB /
   device context / 資料緩衝全部走 `GuestMemory`，而且只讀寫 **guest 驅動透過 DMA API 交出來
   的位址**；資料進出 host 都是拷貝（guest → crosvm 自己的緩衝 → usbfs → host kernel）。
   物理 USB 控制器的 DMA 發生在 host kernel 自己的緩衝上，跟 guest 沒有任何直接對應。
2. **xHCI 是 PCI 裝置，而 PCI host bridge 已經掛著 restricted pool。** crosvm 的 FDT 給
   `/pci` 節點 `memory-region = <restricted-dma-pool>`；Linux 的 `pci_dma_configure()` 讓匯流排
   上每個 PCI 裝置繼承它。xhci 驅動的所有配置（ring、context、scratchpad、URB 緩衝）都經
   DMA API，所以 100% 落在 host 看得到的 swiotlb 區。這比 virtio 還乾淨：virtio 得靠
   `VIRTIO_F_ACCESS_PLATFORM` 才走 DMA API（見 VIRTIO_SND_PROTECTED_VM.md 那次踩雷），
   xHCI 沒有「不走 DMA API」這條路。
3. **實機（5568，stock Ubuntu 26 kernel 7.0.0-30，UEFI 開機，protected）**：guest 選了 device
   tree（firmware 同時發 DT 和 ACPI，arm64 Linux 只要 DT 不是空殼就預設關 ACPI），開機就建了
   256 MiB restricted pool，`pci-host-generic` 和底下 **每一個** PCI 裝置都被指派了這個 pool。
   `lspci` 裡沒有 xHCI，正是 gate 的效果。

為什麼 virtio-gpu 要池而 USB 不用：

| | virtio-gpu | USB（xHCI + usbfs 後端） |
|---|---|---|
| host 端誰碰 guest 記憶體 | host GPU（KGSL）直接 DMA、guest userspace mmap 同一塊 | 只有 crosvm 這個 process，用 CPU 拷貝 |
| 資料量 / 生命週期 | GB 級、常駐、零拷貝是效能前提 | 每筆 URB ≤ 1 MiB、用完即棄、本來就三次拷貝 |
| 頻寬 | 數 GB/s | USB2 ~40 MB/s、USB3 幾百 MB/s，bounce 成本可忽略 |
| guest 驅動能不能指定記憶體來源 | 可以（patched virtio_gpu 找 `droidvm,pool` 節點） | 不行也不需要：由 DMA API 決定，stock 驅動即可 |

「掛 USB 控制器 MMU 空間」= 把 dwc3/xHCI 直通給 guest（VFIO 型）。這條在這批手機上不可行：
- host 的 dwc3 在 `15000000.apps-smmu` 後面（`a600000.dwc3` → iommu_group 37）；直通需要
  hypervisor 把它的 SMMU stream 改到 guest 的 stage-2。GKI host 的 Gunyah 驅動沒有任何裝置指派
  介面（只有 `gh_irq_lend` / `gh_tlmm_vm_mem_access`；`CONFIG_GUNYAH_QCOM_TRUSTED_VM` 是給
  Qualcomm 靜態 TVM 用的），HLOS 起的 VM 拿不到。
- 就算拿得到，整台手機只有這一顆 dwc3（adb、充電、DP 都在上面），給了 guest Android 就沒 USB 了。

## 1. 記憶體模型（host 端，全部對到行號）

crosvm fork = `crosvm_build/external/crosvm @ 2d58205`（`wip/usb` 與 `droidvm` 同 SHA）。

- Gunyah 下 lend 還是 share 由 region purpose 決定，`hypervisor/src/gunyah/mod.rs:431-471`：
  `GuestMemoryRegion` / `Bios` / `ReservedMemory` → **LEND**（host 失去存取）；
  `StaticSwiotlbRegion` / 各種 pool / `SharedFramebuffer` → **SHARE**。
  LEND 走 `GH_VM_ANDROID_LEND_USER_MEM`（`mod.rs:245-278`），SHARE 走 `GH_VM_SET_USER_MEM_REGION`
  （`mod.rs:285-321`）。
- `--swiotlb N`（MiB）：`src/crosvm/cmdline.rs:2536-2544`；沒給時 protected 預設 64 MiB、
  pseudo-unprotected 和 unprotected 不產（`src/crosvm/sys/linux.rs:1699-1716`）。
  Gunyah 宣告 `StaticSwiotlbAllocationRequired`（`hypervisor/src/gunyah/mod.rs:243`），區域放在
  `--mem` 的最頂端（`aarch64/src/lib.rs:358-373`），purpose `StaticSwiotlbRegion`
  （`aarch64/src/lib.rs:1001-1009`）。
- FDT：`/reserved-memory/restricted_dma_reserved@<addr>`，`compatible = "restricted-dma-pool"`
  （`aarch64/src/fdt.rs:153-192`，只在 swiotlb 存在時產，`fdt.rs:1033-1057`）；
  `/pci` 節點 `dma-coherent` + `memory-region = <該 phandle>`（`aarch64/src/fdt.rs:738-753`）。
  這個 tree 沒有 virtio-mmio，所有裝置都是 PCI，所以這一個屬性就蓋住全部。

## 2. xHCI 裝置與 usbfs 後端（crosvm，上游原碼）

- PCI 裝置：`impl PciDevice for XhciController`（`devices/src/usb/xhci/xhci_controller.rs:182`），
  唯一的 BAR 是 64 KiB MMIO（`:42`，`allocate_mmio` `:236-267`）；沒有 shared-memory BAR。
- 所有結構都以 guest 寫進暫存器的 GPA 經 `GuestMemory` 讀寫：
  TRB `ring_buffer.rs:139-144`、event ring `event_ring.rs:82`、DCBAA → device context
  `device_slot.rs:1032-1040`、資料緩衝 `scatter_gather_buffer.rs:115-118, 141-144`。
- 拷貝而非零拷貝：OUT 先從 guest 記憶體抄進線性緩衝再送（`devices/src/usb/backend/endpoint.rs:122-145`），
  IN 完成後抄回（`:253-267`）。`GuestMemory` 映射從未交給 host kernel。
- host 端：`USBDEVFS_SUBMITURB`，buffer 是 crosvm userspace 指標（`usb_util/src/device.rs:246-286`）；
  有 1 MiB 的 usbfs mmap 視窗做 crosvm ↔ host kernel 間的零拷貝（`device.rs:161-179`），失敗
  就退回 heap。介面用 `USBDEVFS_DISCONNECT_CLAIM`（driver 名全零 = 無條件踢掉 host kernel
  驅動再 claim，`device.rs:366-381`）。
- **isochronous 不支援**：`new_isochronous` 帶空的 iso descriptor（`device.rs:647-650`，TODO），
  `handle_transfer_internal` 只處理 Bulk / Interrupt，其餘回 Error（`endpoint.rs:106-118`）。
  USB 音訊、絕大多數 UVC 攝影機透傳不了 —— 這是上游限制，與 protected 無關。
- 執行期掛載：`crosvm usb attach <忽略的四元組> <dev_path> <sock>`（`src/crosvm/cmdline.rs:677-694`）
  → `do_usb_attach` 開檔後送 `VmRequest::UsbCommand(AttachDevice { file })`
  （`vm_control/src/client.rs:125-139`，enum `vm_control/src/lib.rs:251-266`，fd 隨訊息經
  SCM_RIGHTS 傳）；`dev_path` 可以是 `/proc/self/fd/N`，會直接接收已開好的 fd
  （`base/src/sys/linux/mod.rs:524-541, 561-569`）。VMM 端 `device_provider.rs:307-317`。
  另有 C API `crosvm_client_usb_attach`（`crosvm_control/src/lib.rs:524-554`）。最多 16 個 port。
- 裝置建立點：`src/crosvm/sys/linux.rs:1492-1503`，`cfg.usb` 預設 true、`--no-usb` 清掉
  （`config.rs:1422`，`cmdline.rs:3593`）—— 然後被 §結論那段 gate 蓋掉。fork 在 `devices/src/usb`
  與 `usb_util` 零改動。

## 3. guest 端（stock Linux，不用移植）

xhci 驅動的每一種配置都經 DMA API，而 restricted pool 兩邊都接：

| xhci 配置 | 走的 API | restricted pool 下的行為 |
|---|---|---|
| DCBAA、ERST、scratchpad 陣列與頁 | `dma_alloc_coherent` | `__dma_direct_alloc_pages` → `is_swiotlb_for_alloc()` → `swiotlb_alloc()`，直接從 pool 切 |
| ring segment、device/input context、stream context | `dma_pool_*`（底層同上） | 同上 |
| URB 資料（`usb_hcd_map_urb_for_dma`） | `dma_map_single/sg` | `rmem_swiotlb_device_init` 設了 `force_bounce`，每筆都反彈 |
| USB core 小緩衝（`hcd_buffer_alloc`） | `dma_pool` | 同第一列 |

裝置怎麼拿到 pool：`pci_dma_configure()` → `of_dma_configure(bridge->parent->of_node)` →
`of_dma_set_restricted_buffer()` 讀 `/pci` 的 `memory-region`。實機 dmesg 對每個 PCI 裝置都印了
`assigned reserved memory node restricted_dma_reserved@16c000000`。

限制要知道：
- 單次 mapping 上限 = `swiotlb_max_mapping_size()` ≈ 256 KiB（`IO_TLB_SEGSIZE` 128 × 2 KiB）。
  usb-storage / uas 經 `dma_max_mapping_size()` 自己會切；xhci 的 coherent 配置都 ≤ 4 KiB。
- `CONFIG_SWIOTLB_DYNAMIC=y` 的 transient pool 只長預設 swiotlb，**restricted pool 不會長**。
  pool 是所有 PCI 裝置共用的（virtio-blk/net/snd 的 vring 與緩衝也在裡面），耗盡 = mapping 失敗
  = URB 失敗。app 預設 256 MiB（`VMConfig.java:66`），USB 在途量最多幾 MiB，不是問題，但
  要記得 GPU 流量不走這裡（它走池）。

## 4. 實機證據（2026-09-04，5568 TB322FC / 8 Elite，Android 16，host kernel 6.6.118）

host 端 app 起的 VM（`Ubuntu-resolute`，vms.json 內 `usb: true`、`swiotlb_mb: 256`、
`protected_vm: protected_without_firmware`、`boot.protocol: uefi`），crosvm argv 節錄：

```
--mem 4096 --cpus 4 --hypervisor gunyah
--pre-alloc drm-host-mb=64,gpu-guest-mb=1000,...
--protected-vm-without-firmware --no-balloon --disable-sandbox --hugepages
--prepare-lend-mthp-mode chunked --swiotlb 256
--gpu virglrenderer,...,context-types=drm,...,udmabuf=true
... /data/data/cn.classfun.droidvm/usr/share/droidvm/edk2-gunyah.fd --pflash ...
```
（沒有 `--no-usb`，但 gate 在 argv 解析後把 `cfg.usb` 清掉。）

guest 端：

```
7.0.0-30-generic                          # stock Ubuntu；CONFIG_DMA_RESTRICTED_POOL=y
/sys/firmware/devicetree/base 存在        # UEFI 開機仍拿到 DT，Linux 選它
/sys/firmware/acpi 不存在                 # 只代表 Linux 關了 ACPI（DT 優先），firmware 其實兩者都發，見下
CONFIG_USB_XHCI_HCD=y CONFIG_USB_XHCI_PCI=y（內建）；usb-storage/uas/usbhid/cdc-acm/usbnet 皆為 .ko
software IO TLB: Reserved memory: created restricted DMA pool at 0x000000016c000000, size 256 MiB
OF: reserved mem: ... restricted_dma_reserved@16c000000, compatible id restricted-dma-pool
pci-host-generic 10000.pci: assigned reserved memory node restricted_dma_reserved@16c000000
pci 0000:00:00.0 ... 0000:00:0a.0: assigned reserved memory node restricted_dma_reserved@16c000000
/proc/device-tree/pci/memory-region = <0x2>   # PHANDLE_RESTRICTED_DMA_POOL
lspci：virtio gpu/blk/input×4/net/snd/gunyah-accept + pvpanic，沒有 xHCI
```

為什麼 UEFI 開機 Linux 拿到 DT、Windows 拿到 ACPI：FV 裡裝的是 **OvmfPkg** 的
`PlatformHasAcpiDtDxe`（`GunyahFvMain.fdf.inc:148`），它只在 QEMU fw_cfg 有 `etc/table-loader`
時才裝 `PlatformHasAcpi` 協定，否則裝 `PlatformHasDeviceTree`（`edk2/OvmfPkg/PlatformHasAcpiDtDxe/
PlatformHasAcpiDtDxe.c:33-41`）；Gunyah 沒有 fw_cfg，所以 FdtClientDxe 把 crosvm 的 FDT 裝進 EFI
config table。**ACPI 走另一條、不受這個協定影響的鏈**：`AcpiTableDxe` + DynamicTablesPkg
（`KvmtoolCfgMgrDxe` + `FdtHwInfoParserLib` 從同一份 FDT 產 DSDT/FADT/MADT/GTDT/MCFG/IORT/
SSDT-PCIe/SSDT-CPU/SSDT-serial，`GunyahKernel.dsc:55,104`，`GunyahFvMain.fdf.inc:150-156`）
再加兩張 DroidVM 自己的 SSDT：`GunyahRestrictedDmaPoolAcpiDxe` 把 FDT 的 restricted-dma-pool
變成 `\_SB.RDMA`（`_HID RDMA0000`，`_CRS` = 一段 QWordMemory 蓋住 swiotlb 視窗，
`GunyahRestrictedDmaPoolAcpiDxe.c:120-160`），`GunyahPoolAcpiDxe` 把 `droidvm,pool` 節點變成
`\_SB.PLxx`。同一份 firmware 兩種 OS 各取所需。GunyahPkg 自己那份 `GunyahPlatformDxe` 不在 FV 裡。

**Windows 端實機（同機 5568，Windows 11 Enterprise LTSC 26100 ARM64，`--protected-vm-without-firmware
--swiotlb 256`，UEFI）**，用 `user` ssh 進去查：

```
HKLM:\HARDWARE\ACPI：DSDT(ARM-KVMT) FADT RSDT SSDT×8，其中 SSD7 OEMTableID=DMAPOOL（= \_SB.RDMA）
ACPI\RDMA0000 → "Restricted DMA Pool Manager"，Service=rdmapool（oem1.inf, 11.35.27.880），Status OK
Win32_USBController：空（gate 的效果）
C:\Windows\System32\drivers\USBXHCI.SYS：在（inbox，2024-09-05）
在跑的移植驅動：viostor(oem4) NetKVM(oem0) viosnd(oem6) vioinput(oem3) pvmpower(oem2) rdmapool(oem1)
Error：VEN_1AF4&DEV_107C（gunyah-accept，Windows 沒驅動，預期）、1B36:0011 pvpanic（沒裝驅動）
```

host 端 USB：
- 兩台（5566 PLK110 / 5568）都有 `android.hardware.usb.host`，kernel `CONFIG_USB_DWC3_DUAL_ROLE=y`
  + `USB_ROLE_SWITCH` + `USB_XHCI_HCD`，`xhci-hcd` 平台驅動在。調查時 port 都不在 host 角色
  （5568 甚至正以 device 身分接在某台電腦上，`/sys/class/udc/a600000.dwc3/state = configured`），
  `/sys/bus/usb/devices` 空。adb 走網路，USB-C 是空的，OTG 接上裝置 dwc3 就會切 host。
- usbfs 節點規則：ueventd `/dev/bus/usb/* 0660 root usb`。crosvm 由 root daemon fork，
  實測 `uid 0`、`u:r:magisk:s0`，可直接開 `/dev/bus/usb/BBB/DDD`。
- 已有的 app 管線：`--no-usb` 開關（`CrosvmBackendInstance.java:430-431`，UI 在 Basic 分頁
  `VMEditBasicTab.java` 的 `swUsb`，預設 true `VMConfig.java:29,71`）；`UsbHidInput.java` 已有
  完整的 `UsbManager` 列舉 / `requestPermission` / `openDevice` / attach-detach 廣播流程（給外接
  顯示的 HID 輸入用）；控制 socket 是 SEQPACKET `LocalSocket` 直接寫 `VmRequest` JSON
  （`:1589-1624`，目前只有 Exit/Powerbtn/Sleepbtn/Suspend/Resume）。app 從沒呼叫過 `crosvm usb`。

## 5. 風險與要驗的東西

| # | 項目 | 判斷 |
|---|---|---|
| R1 | xHCI 在 pVM 裡初始化（DCBAA / cmd ring / event ring / scratchpad） | 理論全走 DMA API；**第一個實驗就驗這個**：拿掉 gate 起 pVM，guest `lspci`/`dmesg | grep xhci`，host log `host access to lent memory` 必須 0 筆 |
| R2 | 拿掉 gate 後 **protected Windows** guest 也會多一顆 xHCI | 驅動它的是 Microsoft inbox 的 USBXHCI.SYS，不是我們的移植驅動；rdmapool 是 per-driver opt-in（§7），inbox 驅動會把 ring 放進 lent 記憶體 → crosvm 讀 ring 時炸。app 端要對 protected + Windows 預設關 USB 或提示；Windows 要 USB 只能走 pseudo-unprotected |
| R3 | pseudo-unprotected 模式 | 也被 gate 擋（它不是 `Unprotected`）。RAM 整段 SHARE，沒有 swiotlb 也能跑 USB，拿掉 gate 時一併放行 |
| R4 | host 端驅動衝突 | `DISCONNECT_CLAIM` 會踢掉 Android 已綁的驅動（usb-storage → vold 的 OTG 掛載、hid → 輸入）；detach 後上游不會 reconnect kernel 驅動，Android 端裝置「消失」直到重插。可接受，但 UI 要講 |
| R5 | UsbService / 權限 | daemon 是 root，開檔不需要 `UsbManager` 授權；但列舉、熱插拔廣播、使用者選裝置仍該用 `UsbManager`（現成的 `UsbHidInput` 流程）。SELinux：magisk domain 實測可跑 crosvm，開 usbfs 要在 attach 時確認 |
| R6 | isochronous | 上游不支援（§2），audio / UVC 不在範圍；要的話是獨立的一項工程 |
| R7 | swiotlb 容量 | 256 MiB 共用；USB 在途量幾 MiB；OK。但若有人把 `swiotlb_mb` 調到很小要防 |
| R8 | 效能 | 三次拷貝 + 1 MiB usbfs 視窗；USB2 完全無感，USB3 儲存裝置估計 CPU 綁定在幾百 MB/s，夠 |
| R9 | port 角色 | 需要 OTG 線 + 裝置，人在現場插。5566 目前 port 空著（role none）適合測；5568 當時接在電腦上 |

## 6. 實作切分（草案，開工用）

**crosvm（`wip/usb`）** —— 小改：
1. 把 `cmdline.rs:3859-3864` 的無條件 `cfg.usb = false` 改成「guest 有反彈路徑就放行」：
   建議把判斷移到 `linux.rs` swiotlb 解析之後：`isolates_memory() && swiotlb.is_none()` 才關
   USB（並警告），其餘（有 restricted pool、pseudo-unprotected、unprotected）照 `cfg.usb`。
   `cfg.rng = false` 那行不動。
2. xhci / usb_util 不需要改。

**app（`wip/usb`）**：
1. attach/detach 通道：daemon（root）開 `/dev/bus/usb/BBB/DDD`，二選一：
   (a) 用現有 `NativeProcess` 跑 `crosvm usb attach 0:0:0:0 <path> <sock>` / `usb detach <port> <sock>`
   / `usb list`，最省事，fd 傳遞由 crosvm CLI 自己做；
   (b) 在現有 `runControlCommand` 的 `LocalSocket` 上寫 `UsbCommand` JSON 並用
   `setFileDescriptorsForSend` 附 fd，省一次 exec 但要對齊 serde 的 `with_as_descriptor` 編碼。
   先做 (a)。
2. VM 設定：`usb` 之外新增「要透傳的裝置」清單（vid:pid 或 serial 匹配）＋熱插拔自動掛載開關；
   editor 加裝置選擇器，資料來源 `UsbManager.getDeviceList()`（沿用 `UsbHidInput` 的流程含
   `requestPermission`，即使 root 不需要也給使用者一個明確同意）。
3. 熱插拔：daemon 或 app 收 `ACTION_USB_DEVICE_ATTACHED/DETACHED` → 對比清單 → attach/detach。
4. R2：protected + Windows 的 VM 預設 `usb=false` 並在 editor 提示。
5. 既有的 lent-memory 提醒（`OsKernelWithoutRestrictPoolHandler`）已能抓 xhci 的錯誤行，不用改。

**驗收順序**：
1. gate 拿掉的 crosvm → 5566 的 app VM（`usb: true`）→ guest `lspci` 有 xHCI、`dmesg` xhci_hcd 初始化
   無錯、host log 無 lent-memory；
2. OTG 插隨身碟 → attach → guest `lsusb` / `dd` 讀寫 → detach / 拔除；
3. 鍵盤滑鼠（interrupt）、USB serial（cdc-acm，bulk）、USB 網卡；
4. 回歸：pseudo-unprotected + Windows 有 USB；protected + Windows 預設無 xHCI。
   （Unprotected 模式不驗：本地手機都是消費級高通，Unprotected 只在聯發科、Google 和 8 Elite Gen 6
   以後的平台可用；gate 對它的放行只是保留上游行為。）

## 7. EDK2 要不要改？Windows 驅動 repo 要怎麼配合？（2026-09-04 追問）

**EDK2：不用改。**
- Windows 需要的 ACPI 它已經在發（§4 實機清單），xHCI 是一個 PCI function，Windows 自己從
  MCFG / `PNP0A08` 列舉並自動載入 USBXHCI.SYS，不需要任何額外 ACPI 物件；`_PRT` 由
  DynamicTablesPkg 的 SSDT-PCIe 產生器從 crosvm FDT 的 `interrupt-map` 產生，而 crosvm 是逐一列出每個帶 IRQ 的
  PCI 裝置，xHCI 一存在就有它那一項（xHCI 用 INTx，`xhci_controller.rs` 的 `IrqLevelEvent`）。
- firmware 階段的 USB（USB 開機、UEFI 選單用 USB 鍵盤）：FV 已含 `XhciDxe` / `UsbBusDxe` /
  `UsbKbDxe` / `UsbMouseDxe` / `UsbMassStorageDxe`（`GunyahFvMain.fdf.inc:181-187`），它們的 DMA 走
  `PciIo` → `GunyahIoMmuDxe` 的 IOMMU protocol → pool（`GunyahIoMmuDxe.c:302-340`），protected 下
  自動正確，不用動。
- 唯一會碰 EDK2 的假想情境：若走「Windows 端寫 xHCI 過濾驅動把 DMA 導進 rdmapool」，需要一個
  「這顆 xHCI 對應哪個 pool」的 ACPI 連結（Linux `memory-region` 在 ACPI 沒有對應物，現在
  `\_SB.RDMA` 是獨立裝置、沒綁 PCI）。這條路本身不建議（下）。

**gunyah-guest-drivers-windows（`/root/gitrs/DroidVM/gunyah-guest-drivers-windows`）：USB 不需要它，
也幫不上。**
- 機制現況：`rdmapool.sys` 綁 `ACPI\RDMA0000`，讀 `_CRS` 的 memory 資源、`MmMapIoSpace` 映射整個
  視窗、做 bitmap 頁配置器，經 device interface + IOCTL 發配（`rdmapool/rdmapool.c:4-10, 114-146`）；
  `rdmaclient` 是純 WDM 的 client 函式庫，**每個移植驅動自己 link 進來、自己把 ring/資料 stage 進
  視窗**（link 的有 viostor、vioscsi、NetKVM、viosnd、viofs、vioinput、pvmpower；viostor 連
  UNMAP/DISCARD 都得手動經 control slot 反彈，commit 677ed85a）。它是 **per-driver opt-in**，不是
  Linux swiotlb 那種對整條 PCI 匯流排透明的反彈。
- USB 為什麼套不上：xHCI 由 Microsoft inbox `USBXHCI.SYS` 驅動，不能 link rdmaclient、也沒有
  移植版；Windows 沒有任何 ACPI 描述能讓 inbox 驅動把 DMA「搬到指定視窗」（`_DMA` 只限位址範圍，
  且要有 SMMU 才能 remap，不會把緩衝換到另一塊實體頁）。
- 所以 Windows + USB 的選項：
  1. **pseudo-unprotected**（推薦，零改動）：整段 RAM 是 SHARE 的，沒有 lent 區域，inbox
     USBXHCI 直接可用；EDK2、rdmapool、驅動都不用動，只要 crosvm 的 gate 一併放行
     `ProtectedPseudoUnprotected`（§6 crosvm 第 1 點已含）。
  2. 寫 xHCI lower filter 攔 USBXHCI 的 common buffer 配置導進 rdmapool：USBXHCI 走 WDF DMA
     enabler / HAL，沒有可靠攔截點，工程大且不確定；不建議。
  3. protected Windows 明確不支援 USB：app 對 protected + Windows 預設 `usb=false` 並提示（R2）。
- 一句話：Windows 驅動 repo 為 USB **不需要改**；要配合的是 app/crosvm 端「protected Windows 不給
  xHCI、pseudo-unprotected 才給」。

## 8. 實機驗收紀錄（2026-09-04，5568）

crosvm `wip/usb`：`ddb15e0` 拿掉 gate（protected 類型只在沒有 swiotlb 時關 USB；非 aarch64 維持上游
行為）、`cb99117` xHCI 改用 QEMU 的 PCI id `1b36:000d`。手動 launcher 跑，不經 app。

**Linux protected（`--protected-vm-without-firmware --swiotlb 256`，stock Ubuntu 7.0.0-30）— 通過，兩輪。**
- `lspci`：`00:04.0 USB controller [0c03]: Red Hat, Inc. QEMU XHCI Host Controller [1b36:000d]`；
  dmesg `xhci_hcd 0000:00:04.0: assigned reserved memory node restricted_dma_reserved@170000000`；
  host log `host access to lent memory` 0 筆。換 id 後 `quirks 0x10`（原 `0x50`），沒有任何 MSI /
  legacy / TRUST_TX_LENGTH 相關警告。R1 成立。
- 三顆裝置 `crosvm usb attach` 皆 `ok <port>`：隨身碟 `090c:1000` → guest usb-storage、`sda1` NTFS
  唯讀掛載讀到檔案，`dd` 128 MiB 15.4 MB/s（USB 2.0 hub，三次拷貝；效能待議）；讀卡機 `1403:7506`
  （host 無驅動）→ guest 讀齊 CCID descriptor；網卡 `0bda:8153` → guest r8152 綁上、`enx…` 出現，
  host `eth0` 消失。`usb list` = `devices 1 090c 1000 2 1403 7506 3 0bda 8153`。
- detach 後 guest `USB disconnect`；host 介面全部 unbound（證實 kernel 不重綁）→ `drivers_probe`
  後 usb-storage / r8152 回來、vold 重掛 `public:8,97`。`systemctl poweroff` 5～8 秒內 crosvm 退出，
  `pool_avail` 回到 3072、`active_vms=0 served=0`。
- host log 的三條雜訊每輪都在、與功能無關：開機時 `Write to crcr while command ring is running`
  （EDK2 交棒給 OS），attach 時 `device slot is already enabled`、`endpoint is stalled. set state to
  Halted`（descriptor 掃描）。

**Windows pseudo-unprotected（Windows 11 LTSC 26100）— 第一輪失敗，原因是 PCI id。**
- pseudo 模式本身正常：shim 10 ms 分享整段視窗、零 lent-memory，host 端三顆 attach 也都 `ok`。
- 但 guest 的 xHCI 停在 `CM_PROB_FAILED_INSTALL`：inbox `usbxhci.inf` 的 `[Generic.Install.NT]` 有
  `ExcludeID=PCI\VEN_1B73&DEV_1000&CC_0C0330` 與 `ExcludeID=PCI\VEN_1B73&DEV_1400&CC_0C0330`，
  正好是 crosvm 寫死的 Fresco Logic FL1400。上游選它是為了讓 Linux 套 `XHCI_BROKEN_MSI`，但 crosvm 的
  xHCI 沒有 MSI capability（Linux 自己退回 INTx），short packet 也回 `COMP_SHORT_PACKET`，Fresco 的
  quirk 一個都不需要 → 改 `1b36:000d`（qemu-xhci）。
- 第二輪（`1b36:000d`）：Windows 綁上 inbox USBXHCI（`Standard USB 3.0 eXtensible Host Controller - 1.10
  (Microsoft)`，Status OK，root hub OK），但第一次 attach 後 host log 0.83 秒內 9～10 次「stopping all
  device slots and resetting host hub」，root hub 落到 `CM_PROB_FAILED_POST_START`（code 43），裝置從未出現。
- **根因（ETW：USBXHCI + USBHUB3 + UCX providers，`logman` 抓、`tracerpt` 解碼）**：attach 的 port
  change 把 root hub 從低功耗喚醒（`UCX RootHub Initiating Wake` → `EvtDeviceD0Entry`），USBHUB3 第一次
  輪詢全部 16 個 port：port 1（隨身碟）讀到 `0x503`（連線＋enable＋高速）完全正常；但 **port 9～16（空的
  USB 3.0 port）每個都讀到 `PortStatus=0x200`＝有電、無連線、link state = U0**，規範上空 SS port 必須是
  RxDetect（`0x2A0`），於是每個 port 一條 `id=122 Hub Reset Request Due to Port Error`（8 port × 10 輪 = 80 條），
  接著 `id=120 Start of Hub Reset Request` → USBXHCI `Controller Internal Reset`（每次都 NtStatus=0 成功），
  port 狀態沒變 → 迴圈，九輪後放棄。crosvm log 的九次 HCRST 與 ETW 一一對應。
  模型的兩個缺陷（`devices/src/usb/xhci/mod.rs` `portsc_callback`、`usb_hub.rs`）：PORTSC 沒有 LWS（bit 16）
  門控，任何寫入都把 PLS 欄位直接存進去（Windows 寫 0；Linux 的 `xhci_port_state_to_neutral` 會保留 PLS，
  所以 Linux 從沒踩到）；port reset 路徑無條件 `PLS=U0、PED=1`，空 port 也一樣；HCRST 不會把 PORTSC 還原成
  重設值 `0x2A0`。修法：LWS 門控、reset 後空 port 回 RxDetect 且不 enable（有裝置才 U0＋enable，warm reset
  另設 WRC）、`UsbHub::reset` 先把每個 port 還原成重設值再重新宣告仍接著的裝置 → crosvm `94773a3`。
  證據：scratchpad `win-etw/etw_timeline_key.txt`（ETW 時間線）、`attach_window_xhci.txt`。
- 第三輪（`94773a3`）：重置風暴消失，root hub 在 attach 後仍 OK，但 attach 後 134 ms host log
  `removing event handler due to error: failed to send transfer to backend: failed to submit transfer to
  backend`，xHCI 事件處理器被移除、模型停擺，10 秒後 Windows 列舉逾時才重置一次。內層錯誤被
  `xhci_transfer.rs` 的 `map_err(|_| Error::SubmitTransfer)` 丟掉，只能讀碼定位：**Windows 的 USBXHCI 每個
  TD 尾端都掛一個 Event Data TRB**（IOC 設在它上面，拿 TD 的累計長度 EDTLA），Linux 從不發；
  `ScatterGatherBuffer::new` 只收 Normal / DataStage / Isoch，看到 EventData 回 `BadTrbType` →
  `CreateBuffer` → 致命。順帶兩個 Windows 才在乎的錯誤：Event Data 事件的完成碼一律 Success（stall /
  short 也是）、指向 TRB 的事件卻把 ED 旗標設成 1（Linux 不看 ED）。修法：buffer 接受並跳過 Event Data
  TRB、Event Data 事件按 TD 結果給碼、非 Event Data 事件 ED=0、Setup Stage 回報 8 bytes、後端拒絕原因
  記進 log → crosvm `d9735bf`。
- **第四輪（`d9735bf`）— Windows 通過。** 三顆裝置全部 `CM_PROB_NONE`：隨身碟 `USB Mass Storage Device`
  （Get-Disk：`UFD 2.0 Silicon-Power16G` 16 GB MBR；Get-Volume：D: NTFS；唯讀 `Get-ChildItem D:\` 列出
  檔案）；讀卡機綁 inbox `Microsoft Usbccid Smartcard Reader (WUDF)`；網卡綁 `Realtek USB GbE Family
  Controller`（Disconnected，無線材；MAC 00-E0-4C-68-04-3B 原樣透傳）。host log 零次 hub 重置，控制器整
  段存活；剩下的 host log 雜訊與 Linux 相同（`device slot is already enabled`、r8152 列舉時一次 STALL，
  Windows 自行恢復）。detach 後三顆從 PnP 消失，host 驅動還原、vold 重掛，`shutdown /s` 正常退出。
  同版 Linux 回歸乾淨（無 xhci 警告、attach/讀/detach/還原全 OK）。

**M5（Windows 走 app daemon，APK `0.0.6.r218.g1527331` 內含 crosvm `d9735bf`）— 通過。**
- `vm_modify` 把 Windows VM 設定改成 `pseudo_unprotected`（唯一變動的鍵；已永久生效），daemon 起的 argv
  為 `--protected-vm-pseudo-unprotected`、無 `--swiotlb`。
- `droidvm usb-attach` 三顆皆 OK：`USB Mass Storage Device`（Disk 1 Silicon-Power16G MBR、D: NTFS、唯讀列出
  檔案）、`Microsoft Usbccid Smartcard Reader (WUDF)`、`Realtek USB GbE Family Controller`；`usb-vm` /
  `usb-list` 的 attached_vm、port、driver=usbfs 正確。
- detach 讀卡機與網卡 → guest PnP 消失，daemon 0.3 秒內 `drivers_probe`，r8152 回到 Android。
- `vm_stop` 時隨身碟仍接著 → crosvm 退出後 daemon 釋放，2 秒 usb-storage 回來、5 秒 vold 重掛；事件
  6 × `usb_vm_changed` / 6 × `usb_host_changed` 與動作一一對應。最終 pool 3072、`active_vms=0`。
- 同一版本 Linux 煙霧（daemon 路徑）通過；獨立複核 58 項主張，判定 pass-with-notes（只有數字精度與
  措辭問題，無矛盾）。

**結論：目標達成。** Linux protected-without-firmware 與 Windows pseudo-unprotected，經 crosvm 手動
launcher 與 app daemon 兩條路徑，都能 runtime attach 並讀到 USB 裝置。crosvm `wip/usb` 四個 commit：
`ddb15e0`（gate）、`cb99117`（PCI id）、`94773a3`（PORTSC link state / LWS / HCRST 還原）、`d9735bf`
（Event Data TRB）；app `1527331`（daemon runtime attach）。尚未做：M3 app UI、M4 自動接入規則、實體拔線
測試、protected + Windows 在 UI 上的防呆。已知限制：上游不支援 isochronous（USB 音訊/多數攝影機）、
USB 2.0 hub 上隨身碟約 15 MB/s。

app `wip/usb`：`1527331` daemon runtime attach（見 USB_PASSTHROUGH_ANDROID_PLAN.md §2、§3；三路
審查後修正：attach 與 VM 停止的競態用 stop-epoch 解、CLI 逾時改成先 waitFor 再 SIGKILL 並 reap、
attach 失敗也還原 host 驅動、VMM 已不在時 detach 仍可清記錄、daemon 關閉時收尾）。

**階段 B（經 app daemon，APK `0.0.6.r218.g1527331`，5568 Ubuntu protected）— 通過。**
- 三種路徑 attach（console 依名稱、IPC、console 依 id）皆 `ok`，guest lsusb / lsblk / r8152 證據齊；
  `usb-vm`、`usb-list` 的 attached_vm/port 正確。
- 七個錯誤路徑訊息與原始碼逐字一致（hub、不存在、重複 attach、錯 port、非數字 port、缺 device、VM 不存在）。
- detach 依 sysfs 與依 port 都行，daemon 自動 `drivers_probe`，r8152 一秒內回來。
- 第一輪抓到兩個 bug 並修掉：釋放做在 STOPPING（crosvm 還握著 usbfs，probe 被跳過，隨身碟停在無驅動
  80 秒）→ 改成 STOPPED/REBOOTING 才釋放並等 `usbfs` link 消失；`usb-list` 的 driver 欄位是舊快照（inotify
  看不到驅動綁定）→ 每次直接掃 sysfs。第二輪：vm_stop 後 1 秒 usb-storage 回來、vold 重掛（日誌：釋放在
  `-> STOPPED` 之後 1 ms）、`usb-list` 即時、事件 `usb_vm_changed` / `usb_host_changed` 內容正確。
- 部署注意：APK 升級後 app 會停在 setup 精靈的「預建置檔案解壓成功」頁等人按下一步，daemon 只有
  MainActivity 才會起；升級也不會殺掉舊的 root daemon，要 `stop-all` → `kill <pid>` → `force-stop` → 重開。

## 9. Isochronous（M6，2026-09-04 開工）

現況（code map 見 scratchpad `m6-iso-codemap.md`）：`endpoint.rs` 的 `handle_transfer` 在 transfer-type
與 endpoint-type 兩個 match 都沒有 Isochronous 分支；`usb_util::Transfer::new_isochronous` 送空的
packet 陣列（usbfs 回 EINVAL），也沒設 `ISO_ASAP`；reap 回來的 `iso_frame_desc[i].actual_length/status`
從未被讀；**ring buffer controller 每次完成才 dequeue 下一個 TD（深度 1）**，這對 isochronous 是結構性
的 underrun，補 packet 語意也救不了。

v1 設計：
- xHCI 規範一個 Isoch TD = 一個 packet（Linux `xhci_queue_isoc_tx` 每個 packet 一個 TD；Windows 同），
  所以一個 TD → 一個 `number_of_packets=1`、`ISO_ASAP` 的 usbfs URB，packet 長度 = TD 的 TRB 長度總和；
  usbfs 會用同一份端點描述元檢查上限，guest 給的長度本來就來自那份描述元。
- 深度：endpoint context type 為 Isoch OUT(1)/IN(5) 的 ring，在每次事件把 ring 上所有 TD 一次 dequeue
  送出（`RingBufferController::set_dequeue_all`），等於真實硬體逐 frame 走完整條 ring；bulk / interrupt /
  control 維持深度 1，行為不變。
- 逐 packet 結果：讀 `iso_frame_desc[0]`；短包走既有 ShortPacket 事件（residual = TRB 長度 − actual，
  Linux 反推 actual_length）；packet 級錯誤（-EXDEV 漏服務、-EPROTO、-EOVERFLOW）v1 先回 0 byte 短包
  （guest 看到一個空 frame），URB 級 ENODEV/ENOENT/EPIPE 維持現有對應。
- v1 不存 max packet size / interval、不做批次、不動 1 MiB DMA 視窗（iso 封包多半退回 Vec，拷貝成本
  在 USB 2.0 頻寬下可忽略）；缺的完成碼（MissedService 10、RingUnderrun 14、RingOverrun 15、
  IsochBufferOverrun 31）與 BEI 留給 v2。

拷貝次數：isochronous 的下限是 host 端 1 次（usbfs 只收自己 mmap 的 coherent 緩衝或任意使用者指標，
後者 kernel 會 copy）。Linux 的 snd-usb-audio / uvcvideo 用 `usb_alloc_coherent` /
`dma_alloc_noncontiguous` 配 iso 緩衝，在 restricted pool 下直接落在池裡，沒有 swiotlb 反彈；Windows
pseudo-unprotected 更沒有。真正決定成敗的是 packet 語意與深度，不是拷貝。

驗證需要有 isochronous 端點的裝置：USB 音效（UAC1 耳麥/DAC：iso OUT + IN，時序最嚴）與 UVC 攝影機
（iso IN 大頻寬，選 MJPEG）。5568 目前的三顆（隨身碟、r8152、CCID 讀卡機）都只有 bulk/interrupt。

M6 v1 實作：crosvm `b0a47ea`（usb_util 的 `new_isochronous` 帶 packet 陣列 + `ISO_ASAP` + 逐 packet
accessor；後端 `build_isochronous_transfer`；endpoint 的 Isochronous 分支；`RingBufferController::
set_dequeue_all`；device_slot 對 endpoint context type 1/5 啟用）。兩路審查修掉四個 v1 設計盲點：
- URB 狀態必須先於 packet 描述判定（我的 pseudo-code 順序錯了，會讓拔線的 NoDevice 被遮掉、port 不會 detach）。
- drain 迴圈要有上限（256/事件，超過就自我 signal 下一輪）；ring 是 guest 記憶體，Link TRB 不翻 cycle
  會讓它無限產出，且迴圈在 `state` 鎖內跑，會卡住整個事件迴圈。
- Stop Endpoint 的 latch（`RingBufferStopCallback`）是每個 controller 一份、在第一次空 dequeue 就釋放；
  有 N 個 in-flight 時會提前回報「已停」。加 `TransferDescriptorHandler::is_quiesced()`，只有 handler
  沒有 pending TD 時才進 Stopped / 釋放 latch。
- usbfs 拒絕單一 iso URB（例如 SET_INTERFACE 還沒落地前的 packet 超長）原本會被對應成 NoDevice 而拔掉
  整個 port；改成掉一幀。
驗證裝置（5568）：AB13X USB Audio `0020:0b21`（FS，iface1 alt1 EP 0x03 Isoc OUT 384 B、iface2 alt1
EP 0x83 Isoc IN 208 B、bInterval 1）與 icSpring 攝影機 `32e6:9221`（HS，iface1 alt1～6 EP 0x82 Isoc IN
1024×3 → 512×1 B/µframe、iface3 alt1 EP 0x85 Isoc IN 40 B 麥克風）。

### 9.1 驗收結果（2026-09-05，5568，crosvm `b0a47ea`）

**Linux（protected-without-firmware，`--swiotlb 256`）：isochronous 完全通過，音效與攝影機兩路都是實跑實測。**
- USB 音效 `0020:0b21`：guest 認到 `card 0 AB13X USB Audio`（full speed）。`speaker-test -c2 -r48000`
  rc=0，pcm status 兩秒間 hw_ptr 前進 48864 frames ≈ 48.9 kHz（就是標稱值），48000/2ch 一次成功、沒退
  44100/mono；`arecord -r44100 -c1 -d5` rc=0，檔案 441044 B，sox 讀到剛好 220500 samples = 5.000 s。
  guest kernel log 整段 audio 零 xrun/underrun/EPROTO。
- UVC 攝影機 `32e6:9221`：`--list-formats-ext` 完整保留 host 的 MJPG/YUYV 清單。640×480 MJPG 手動短曝光
  29.98 fps、720p 29.95 fps、1080p 29.84 fps，SOI 標記逐幀對得上（90/90、60/60），ffmpeg 抽幀都成功；
  YUYV 640×480 手動曝光 60 幀 = 36864000 B 剛好 60×614400（逐幀零截斷，18.4 MB/s 持續 iso IN）。第一輪
  ~16 fps 是相機自身在暗場拉長曝光，非傳輸問題（改手動曝光即回 30 fps）。攝影機自帶的 UAC 麥克風
  （iface3 EP 0x85 Isoc IN）也認成 `card 0 icspring camera`，`arecord -r48000` 讀到剛好 144000 samples = 3.000 s。
- host log 整段：`backend rejected transfer`＝0、`dropping the frame`＝0、`cannot build isochronous`＝0。
  唯一雜訊是串流停止時 crosvm 對 kernel 已完成的 URB 發 DISCARDURB（ioctl 0x550b）拿到 EINVAL（無害）。
  detach 後 guest 5 秒內聲卡/影像節點全消失，host 端 drivers_probe 收回。

**Windows（pseudo-unprotected）：isochronous 傳輸層沒被測到就先卡住，卡在一個「控制端點失速回復」的
xHCI 模型缺陷——不是 isochronous 的問題。**
- 現象：attach 音效後 guest PnP 認到 AB13X（MEDIA class），但音效節點起不來，落到 `CM_PROB_FAILED_START`
  （code 10，ProblemStatus `0xC0000120` = STATUS_CANCELLED），`waveOutGetNumDevs=0`。整段 host log 只有
  `slot_1 ep_1`（控制端點）活動，isoch ring（ep_3/ep_5）從未開啟。
- 根因（ETW：USBXHCI+USBHUB3+UCX+Kernel-PnP，`logman` 抓、`tracerpt` 解，evidence 在 scratchpad
  `m6-windows-rerun/usbtrace-audio.xml`）：列舉/設定過程中控制端點被 device STALL 一次（很常見，音效裝置對
  不支援的 class request 回 STALL），Windows 依規範送一對命令回復——**Reset Endpoint（slot 1 DCI 1，crosvm
  回 code 1 成功）＋ Set TR Dequeue Pointer（slot 1 DCI 1，新 dequeue ptr `0x177ebb800`，DCS=1）**。crosvm
  的 command ring **對這顆 Set TR Dequeue Pointer 從未送出 Command Completion Event**。3 秒後 Windows 的
  command-ring watchdog 觸發（Kernel-PnP 902），5 秒後嘗試 abort（host log `Write to crcr while command ring
  is running`），再 5 秒 abort 逾時，最後整台 controller internal reset、slot/endpoint 全刪，裝置 FAILED_START。
- **根因（2026-09-05 定位，crosvm `be6ad1c` 修）：不在 command ring，在 interrupter 的 interrupt moderation。**
  `interrupter.rs` 每次發中斷記下時間並把 `moderation_counter` 設成 guest 寫的 IMODI（預設 1 ms）；之後每
  加一個事件呼叫 `interrupt_if_needed()`，它要求距上次中斷 ≥ 250 ns × counter 才肯發，**還沒到就直接 return，
  沒有任何 timer 會在窗口結束後補發**。真實硬體的 moderation 是「延到窗口結束」，crosvm 是「窗口內的事件
  不發」，那個事件要等到下一個事件進來才被順便送出；guest 若正在等的就是它、且沒有別的事件會再來，就永遠
  等不到。對上時間軸：Reset Endpoint 完成→中斷（t0）；Windows 在同一個 DPC 裡處理完、立刻送 Set TR Dequeue
  （ETW 三條都是 pid 3068 同一 thread）；crosvm 在 t0 + 100～300 µs 完成它，落在窗口內，中斷被吞掉，之後這台
  裝置再無事件。Linux 沒事是因為 xhci 驅動把 Reset Endpoint + Set TR Dequeue 一起排進 ring、只敲一次 doorbell，
  兩個完成事件在同一輪進 ring，第一個中斷一次收兩個。9/4 那次的另一種死法（三次 stall 各隔 4 秒、無 reset）
  是同一個 bug 吞掉**控制傳輸**的完成中斷：usbaudio 請求 4 秒逾時 STATUS_CANCELLED，取消（那些週期性的
  「ep_1 is already stopped」就是 Stop Endpoint）重試，裝置再 STALL，三次後 FAILED_START。bulk 三顆沒事是
  因為流量密集，被吞的中斷很快被下一個事件補上。
- 修法（`be6ad1c`）：`Interrupter` 內加一個 one-shot timerfd，`interrupt_if_needed()` 在窗口內有事件時把
  timer 設到窗口結束（一個窗口只 arm 一次），新的 `IntrModerationHandler` 掛在 xHCI event loop 上，timer 到期
  再呼叫一次 `interrupt_if_needed()`。單元測試三個：無 moderation 每事件都中斷；窗口內事件在窗口結束後被送達
  （修正前此測試失敗）；一個窗口內多個事件只 arm 一次。
- **第二層（`be6ad1c` 裝上去重驗後露出，crosvm `453d09d` 修）**：moderation 修好後 controller 不再被 reset
  （53 條命令全配對、無 watchdog），但 STALL 之後 Windows 送的 Reset Endpoint + Set TR Dequeue（指標
  `0x17495b400`、DCS=1）crosvm 都回成功，接下來那個控制傳輸卻永遠不執行；Windows 每 7 秒 Stop Endpoint →
  Set TR Dequeue 同一位址重試，usbaudio 6 次後 FAILED_START，usbvideo 的 DeviceStart 根本回不來。用現有
  binary 開 `devices::usb::xhci=debug` 重跑一次 attach 就抓到：每次 Set TR Dequeue + doorbell 之後 EP0 ring
  印 `cycle bit does not match, self cycle false`——crosvm 的 consumer cycle 是 0、Windows 給的 DCS 是 1，
  ring 把合法 TRB 當成不屬於自己的、回報「空」。兩個規範缺口疊出這個結果：(a) endpoint 進 Halted 後 ring
  controller 沒停，繼續把 guest 排在失敗 TD 後面的 TD 拿去執行（走過 link TRB 就翻了 cycle）；(b)
  `set_tr_dequeue_ptr` 只設指標、不套用命令帶的 DCS（spec 6.4.3.9）。Linux 沒踩到是因為它的 Set TR Dequeue
  總是指到 crosvm 已經走到的位置。修法：`RingBufferController::halt()` 在 `halt_endpoint` 時把 ring 停在
  Stopped（並釋放等待中的 stop latch）；Set TR Dequeue 把 DCS 套到 ring 與 endpoint context。單元測試：halted
  ring 不再吐出下一個 TD、doorbell 後從原處續跑。
- 順帶查到、未修的次要缺陷：CRCR 的 Command Abort/Stop（CA/CS）沒實作，所以命令逾時時 Windows 的 abort 救不回來、
  直接升級成整台 reset（有了上面兩修正後不應再走到這裡）。

### 9.2 Windows 重驗（2026-09-05，crosvm `4c6d149` → `d2f4b57`）

`4c6d149`（moderation timer + halted ring + DCS + SETUP 重啟）裝上去後，Windows 這邊終於走到 isochronous：
- 兩次 ETW（音效、攝影機）**anomalies=0**：沒有 watchdog、沒有 command timeout、沒有 controller reset；命令
  submitted==completed。attach/detach 都乾淨，host 驅動每次都收回。
- **攝影機通過**：Camera 節點 OK prob=0，用排程工作在 console session（session 1）跑 WinRT MediaCapture：
  `photo ok ms=688 size=45759`（有效 JPEG 1920×1080 baseline）、6 秒 H.264 MP4 `size=8529`、ffprobe 53 幀
  640×480。EP5（iso IN）203 個 URB、7 秒連續、中位間隔 16 ms，沒有任何停頓。注意事項：(a) MF frame server
  只在互動 session 裡才看得到裝置（ssh 的 session 0 永遠 0 台），所以用 `Register-ScheduledTask` +
  `LogonType Interactive` 在 console session 跑；(b) attach 後第一次開啟會回 `A device which does not exist
  was specified`，20～30 秒後重試就成功，frame server 需要暖機；(c) 影像是全黑（stdev 0，鏡頭對著暗處），
  結構（JPEG/H.264、幀數、時長）都是真的。錄影停止時 host log 噴 311 條 `failed to cancel ... DISCARDURB
  EINVAL`（對已完成的 URB 取消，無害）。
- **音效只通一半**：MEDIA 節點 OK prob=0、Render/Capture endpoint 都是 state=1、waveOut=waveIn=1，iso OUT
  真的有資料（EP6 638 個 URB、0 rejected），但 5.7 秒的 WAV 要放 **31 秒**，錄音 rec.wav 是 0 byte。ETW 看到
  OUT 串流每次剛好跑 **1.023 秒（≈1020 個 1 ms packet）就停 9.3 秒**，usbaudio 逾時後 Stop Endpoint → Set TR
  Dequeue 回 ring 開頭（DCS=1）重來，6 次循環；IN 也是一段 1.02 秒後全靜。
- **根因：MFINDEX 是死的。** `xhci_regs.rs` 把 runtime 暫存器 0x3000（MFINDEX，每 125 µs 加一的 microframe
  計數器）做成 `static_register!` 恆為 0。USBXHCI 排 isochronous TD 的 frame ID 是相對 MFINDEX 算的，最多排到
  MFINDEX 前方約 1024 個 frame；計數器不動，1.024 秒後就排不下去，等到 URB 逾時才重置管線。Linux 的
  snd-usb-audio 不看 MFINDEX（ISO_ASAP 靠主機排程），所以 Linux 沒事。修法（`d2f4b57`）：`register_space`
  加 `set_read_cb`，MFINDEX 讀取回傳自上次 HCRST 起的 125 µs tick 數（14 位元繞回）。實機重驗進行中。
- 未做：USBCMD.EWE 的 MFINDEX Wrap Event（每 2.048 秒一個事件 TRB）；若 Windows 有開 EWE 再補。

**結論：M6「把 isochronous 接線」在 protected Linux（本專案主目標）已達成並實測通過（音效播放/錄音、
攝影機 30 fps、攝影機麥克風）。Windows pseudo-unprotected 的 isochronous 被一個獨立的、與 iso 無關的 interrupter
中斷節流缺陷擋住，已在 `be6ad1c` + `453d09d` 修正，實機重驗見 §9.2；USB 基本功能（bulk 三顆）在 Windows pseudo 仍如 §8 驗過可用。**

