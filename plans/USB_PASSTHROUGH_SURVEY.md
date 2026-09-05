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

**新缺陷（2026-09-05 深夜由 M4 的「VM 開機觸發」測出，crosvm `11c5462` 仍在，修正中）：HCRST 沒有重置
command ring／CRCR／interrupter，開機前就接上的裝置會讓整台 xHCI 在 guest kernel 起來之前就死掉。**
- 現象（5568 的 Ubuntu app VM，daemon 的自動接入規則在 `vm_start` 後約 10 秒 attach，也就是 guest firmware
  還沒碰 xHCI 之前；3/3 必現）：`usb_hub: backend attached to port N` ＋ `port N changed before the guest set up
  its event ring; the change waits in PORTSC`，1.2 ms 後 `device_slot: xhci: stopping all device slots and
  resetting host hub`（guest firmware EDK2 XhciDxe 寫 USBCMD.HCRST），2 ms 後 ERROR `Write to crcr while command
  ring is running`（firmware 的 CRCR 寫入被打回），再 170 ms 後 ERROR `removing event handler due to error:
  cannot dequeue transfer descriptor: cannot read guest memory: invalid guest address 0x0`。事件處理器就此消失，
  23 秒後才起來的 guest kernel 看到一台死的 controller：dmesg `Abort failed to stop command ring: -110 /
  xHCI host controller not responding, assume dead / HC died; cleaning up`，`lsusb` 只剩兩顆 root hub。
- 證據：scratchpad `m6b/m4/run2/3F-crosvm.log` 4532-4543、`3G-crosvm.log` 4836-4844（F/R/G 三次開機同一條鏈：
  13:48:57.844/.847/58.017、13:54:02.642/.645/.815、13:58:56.306/.308/.479）。審核員比對歷史 log：
  `stopping all device slots` ＋ `Write to crcr while command ring is running` 這一對**每次開機都出現**
  （在 `display backend android opened` 之後約 270 ms，改版前 13 次），因為那時沒有任何 port 連線、firmware
  不會發命令，所以一直無害；真正新的只有位址 0 那條（改版前 0 次、本輪 3 次）。kernel 自己 HCRST 之後約 5.5 秒
  的第二條 CRCR 打回，是 kernel 命令逾時 5 秒後的 abort（CRCR.CA），是結果不是原因。
- 根因：`xhci_regs.rs:322-330` 的 crcr 暫存器 `reset_value: 9` ＝ RCS（bit 0）| CRR（bit 3）——**CRR 從上電就是 1**，
  而 `guest_writeable_mask` 0xFFFFFFFFFFFFFFC7 不讓 guest 寫 bit 3，guest 自己清不掉；`Xhci::reset()`
  （`mod.rs:467`）只設 USBSTS.CNR、停 slot 的 transfer ring、重置 hub，**不碰 CRCR**（CRR 續留 →
  `crcr_callback`（`mod.rs:313`）把 guest 的下一次 CRCR 寫入打回並回傳舊值，dequeue pointer 永遠沒被換過）、
  不重置 command ring controller（初值 `GuestAddress(0)`）、不重置 interrupter 的暫存器與狀態
  （IMAN/IMOD/ERSTSZ/ERSTBA/ERDP、event ring）、也不重置 DCBAAP/CONFIG；整個 crosvm 只有 USBCMD R/S=0 那條路
  （`mod.rs:298`）會清 CRR。firmware 期間就有 port 連線時，firmware 會發 Enable Slot、敲 doorbell 0，
  command ring controller 於是從 0x0 開始讀 TRB，`event_loop` 一收到錯誤就把整個處理器移除。
- 規範（xHCI 1.2 §4.2、§5.4.1 USBCMD.HCRST、§5.4.5 CRCR）：HCRST 要「把內部狀態機與暫存器回到初始值」——
  USBCMD=0（R/S=0）、USBSTS.HCH=1、CRCR=0（CRR=0、指標 0、RCS 0）、DCBAAP=0、CONFIG=0、DNCTRL=0、IMAN=0、
  IMOD 預設、ERSTSZ/ERSTBA/ERDP=0、所有 device slot disable、port reset；CRCR 的預設值本來就是 0，
  CRR 是它唯一可讀的位元。
- 修法（進行中）：`Xhci::reset()` 等所有 ring 停妥之後一次做完——CRCR 歸 0、command ring controller 歸位
  （dequeue pointer 0、consumer cycle 回初值、狀態 Stopped）、interrupter 回到「未初始化」的初始狀態
  （event ring、IMAN/IMOD/ERSTSZ/ERSTBA/ERDP、moderation timer 解除）、DCBAAP/CONFIG 歸 0、USBSTS 清 CNR 並設
  HCH；crcr 暫存器的 `reset_value` 改成 0（規範預設值），寫入遮罩維持不讓 guest 設 CRR。
- 一併關掉的風險：`11c5462` 的延後 PORTSC 是靠「event ring 尚未初始化」判斷的，但 HCRST 之後 interrupter 還握著
  firmware 那份 event ring；kernel 自己 HCRST 時 hub reset 重貼的 port change 事件會被寫進 firmware 的 ERST
  記憶體——那塊記憶體已經歸 kernel 用了，是一條會默默弄髒 guest 記憶體的路。把 interrupter 一起重置就沒了。

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
- Linux 回歸（`4c6d149`，同日）：播放 OK（hw_ptr 45744→94032→142608，≈48000/s，0 xrun）；攝影機 MJPG 640
  29.98 fps / 720p 29.97 fps、SOI 90/90、YUYV 36864000 B 剛好 60 幀、攝影機 mic 144000 samples 都 OK。AB13X 錄音
  0 samples——但**同一顆麥克風在 Android host 上直接用 tinycap 也是 0 frames**（開得起來、第一次 read 就失敗，
  重新列舉也一樣），攝影機 mic 在 host 上 tinycap 正常；hub 沒有 per-port 電源控制，只能實體重插救。判定是
  裝置本身壞了，不是 crosvm 回歸（9/4 那輪它在 guest 裡是好的）。isochronous IN 的驗證改用攝影機 mic。
- **`d2f4b57` 全套重驗（2026-09-05 下午，workflow `usb-m6-final-verify`，另有獨立審核員重解 ETW/重讀原始檔）：**
  - Windows（pseudo，手動 launcher）：播放 PlaySync ×3 = 5281 ms（ssh）/ 5279 ms（console session），ETW EP6
    兩段播放各是**一段不中斷的 burst**（5.137 s/507 URB、7.324 s/709 URB，最大內部間隔 85/142 ms）；攝影機拍照
    50162 B JPEG 1920×1080、錄影 31821 B H.264 640×480 86 幀（MediaCapture VGA profile 實際 15 fps，是編碼器不是
    傳輸）；攝影機 mic 錄音 889130 B（EP11 每 10 ms 一個 URB、508 URB/5.03 s、間隔 ≤ 13 ms）；ETW anomalies=0；
    host log iso 計數全 0；detach 後 host 驅動收回、關機乾淨、pool 3072。
  - Linux（protected，手動 launcher）：播放 hw_ptr 45456→94032→142320；攝影機 MJPG 640 29.95 fps、SOI 90/90；
    YUYV 18432000 B 剛好 30 幀；攝影機 mic 48000 samples（RMS 0.0034）。
  - App 路徑：新 APK（f1a8c1ee…）安裝成功、app 解出的 crosvm 由 73d635e2 → 78508ec1（d2f4b57）；Ubuntu app VM
    透過 daemon `droidvm usb-attach` 攝影機 30.00 fps、SOI 90/90、mic 48000 samples；IPC usb_detach 後 host 驅動
    **自己**回來；音訊播放 hw_ptr 44880→93168→141744；裝置掛著 vm_stop → 5 秒內自動釋放回 host。
  - Windows app VM 第一次沒開起來：它的 VM 設定不知何時回到 `protected_without_firmware`（BSOD 0x7B），用
    `vm_modify` 改回 `pseudo_unprotected` 後另行重驗（見下）。
- Windows app VM 重驗（`vm_modify` 改回 pseudo_unprotected 後，workflow `usb-m6-app-windows` + 審核）：daemon 起的
  crosvm 帶 `--protected-vm-pseudo-unprotected`；IPC usb_attach 音訊 → PlaySync 5258/5229 ms、兩個 Render endpoint
  state=1、waveOut=2（播放期間 virtio-snd 沒開 endpoint，證明聲音真的走 USB）；usb_detach 後 1 秒內 host 驅動自己回來；
  攝影機拍照 45759 B、錄影 19074 B（h264 177 幀/5.9 s ≈ 30 fps）、mic 707438 B（96% 非零樣本）；攝影機掛著 vm_stop
  → 13 秒內自動釋放；手機乾淨。兩個 app 端（非 USB）的發現：(1) 第一次 vm_start 進了 WinRE（先前 protected 模式
  BSOD 0x7B 讓 Windows 標記開機失敗），WinRE 沒有 virtio-input 驅動、app 的觸控/鍵盤無效，只能 vm_stop+vm_start；
  (2) `vm_stop` 是立即斷電（crosvm 0.1 s 內 exit），不是 guest 優雅關機，NTFS 留髒卷、可能再次觸發 WinRE——建議
  daemon 先送 guest shutdown（ACPI/agent）再收 crosvm。
- **`76ed342` 驗收（workflow `usb-m6-resume-verify` + 審核）：**
  - Windows（手動 launcher）：attach 攝影機、閒置 65 s（ETW 證明 D0 Exit→D3 於列舉後 35 s、在 D3 待了 81.7 s）後
    **第一次**開啟：拍照 45759 B、錄影 19098 B（177 幀）一次成功；再閒置 82.8 s 後 mic 第一次錄音 714494 B
    一次成功；ETW **Surprise Removal = 0**、兩次喚醒 host log **零** 再列舉；AB13X 閒置 70 s 後第一次 PlaySync
    5414 ms 一次成功。`failed to cancel` 全 log = 0。
  - Linux（protected）：播放 hw_ptr 44880→93744→142320、MJPG 640 29.99 fps SOI 90/90、YUYV 剛好 30 幀、
    攝影機 mic 48000 samples，`failed to cancel` = 0（前一版 62 條）。
  - 最終 APK（md5 8b521e9…，crosvm 7a371d1…）安裝成功；Ubuntu app 路徑攝影機 30.00 fps、mic 48000、IPC detach
    後 12 秒內 host 驅動自己回來。Windows app 路徑當輪沒跑成（設定又回 protected，見下一條），另跑
    `usb-m6-app-windows-final`。
- **Windows app 路徑最終驗收（`usb-m6-app-windows-final`，crosvm `76ed342` 由 app 自己解出）：** pseudo 正常開機
  （無 WinRE）；IPC usb_attach 音訊、閒置 45 s 後第一次 PlaySync 6892 ms 一次成功；攝影機閒置 45 s 後第一次拍照
  45759 B / 錄影 19157 B（178 幀）一次成功；攝影機 mic 707438 B 一次成功；detach 後 host 驅動 0 秒內自己回來；
  攝影機掛著 vm_stop → 3 秒內釋放；本輪 crosvm log `failed to cancel` = 0；手機乾淨。審核員逐項 CONFIRMED。
- **app 端發現：daemon 的 `vm_modify` 不落地。** `VMInstanceStore.modifyVM()` 只換掉記憶體裡的 instance，
  `files/vms.json`（app uid 擁有）只有 UI 會寫；所以 M5 時把 Windows VM 改成 pseudo_unprotected 只活在舊 daemon
  記憶體裡，daemon 一重啟（裝 APK 必經）就回到 protected_without_firmware，Windows 直接 BSOD 0x7B。這次改用
  「停 daemon → 以 root 改 vms.json（保留 u0_a359:600）→ 重啟 app」才真正持久。M3/M4 做 app UI 時要一併處理
  daemon 側修改的持久化（或明確規定只有 UI 能改設定）。
- `76ed342`：stream 停止時對已完成 URB 的 DISCARDURB 回 EINVAL，改成 `TransferAlreadyCompleted`、debug 級，不再每次
  停串流噴數百行 ERROR。
- **審核員抓到的真問題（`7b6a79c` 修）：Windows selective suspend 喚醒後第一次開啟裝置必失敗。** ETW：閒置 ~14 s
  後裝置 D3、hub D0 Exit；喚醒時 hub 讀 port 1 = `0x507`（suspended），對 port 做 resume 後**等 500 ms 的
  Port Link State Change 事件**——crosvm 的 `portsc_callback` 只把 PLS 寫進去、從不設 PLC、不發 port status change
  → USBHUB3 判定裝置消失（Surprise Removal）→ reset port 重新列舉（所以 host log 每次喚醒都有一組 stall/already
  stopped）→ 第二次開啟才成功。Linux 是輪詢 PLS 所以沒事。修法：LWS 寫入把已連線的 port 從 U3/Resume 帶回 U0
  時，設 PLC（bit 22）並送 Port Status Change Event（spec 4.15.2.2）。
- 未做：USBCMD.EWE 的 MFINDEX Wrap Event（每 2.048 秒一個事件 TRB）；若 Windows 有開 EWE 再補。
- 未做：**stream context 的 SCT=0 容忍**——`create_stream_trcs()` 現在要求主 Stream Context Array 的每一格
  都是 Linear（SCT=1），Windows 的 UASP 給了 SCT=0 的格子就整個 Configure Endpoint 失敗；而且**guest 造成的
  context 錯誤必須回一個 completion code 給 command ring**，不能像現在這樣把 xHCI 的事件處理器整個拆掉
  （拆掉之後這台 VM 的 xHCI 就再也回不來）。這是 §9.3 Windows 那列 FAILED 的唯一原因。
- 未做：**bulk 的 drain-ahead / 讓多筆 URB 同時在途**。ring buffer controller 現在對 bulk 仍是深度 1
  （完成才 dequeue 下一個 TD），單佇列吞吐量因此被每筆請求的來回延遲綁住——§9.3 量到 qd1 只有 host 的
  63%／71%，但 qd8 一補上就回到 385–389 MB/s。iso 已經有 `set_dequeue_all`，bulk 需要一個有上限的等價機制。

**結論：M6「把 isochronous 接線」在 protected Linux（本專案主目標）已達成並實測通過（音效播放/錄音、
攝影機 30 fps、攝影機麥克風）。Windows pseudo-unprotected 起初被四層與 iso 無關的 xHCI 模型缺陷擋住（中斷節流丟中斷、halted ring 續跑 + DCS、
控制傳輸狀態機、MFINDEX 不動）加一個 resume 缺陷，全部在 `be6ad1c`…`76ed342` 修掉；最終在兩種 guest、手動 launcher 與
app daemon 路徑上，USB 音訊播放、UVC 攝影機影像、攝影機麥克風錄音都實測通過並經獨立審核（§9.2）。**

### 9.3 USB 3.0 吞吐量（UNITEK NVMe 外接盒，`152d:a583`，UAS）

2026-09-05 在 5568 上量的，crosvm `11c5462`（`wip/usb` HEAD；手動 launcher 跑的是
`/data/local/tmp/usbtest/crosvm`，本輪沒留這支的 md5，同一版由 app 解出來的副本 md5
`69aa3984be32eeec993c6161b7cdc05d`）。裝置是 UNITEK NVMe 外接盒 `152d:a583`（JMicron，serial
DD564198838E9），插在 `0bda:0411` USB3.2 hub 底下、sysfs `2-1.1`、`speed=5000`（SuperSpeed /
USB 3.x Gen1），host 端驅動 `uas`，區塊裝置 `sdg` = 8001573552 × 512 B = 4.10 TB（3.73 TiB），
`max_sectors_kb=512`（hw 也是 512）。全程唯讀：dd 一律 `of=/dev/null`、fio 一律
`--readonly --direct=1`、兩個 guest 進去先 `blockdev --setro`（回 `getro=1`）、guest 內從不掛載、
Windows 在 attach 前先關 automount（`mountvol /N`，`NoAutoMount` 空→1，事後還原成 0）。

- **Launcher / VM**：Linux protected 用手動 launcher `run_linux.sh`
  （`--protected-vm-without-firmware --no-balloon --disable-sandbox --hugepages
  --prepare-lend-mthp-mode chunked --swiotlb 256`、`--mem 4096 --cpus 4`、Ubuntu resolute qcow2）；
  Linux pseudo 用同一份 launcher 只改四處（`--protected-vm-pseudo-unprotected`、拿掉 `--swiotlb 256`、
  加 `DROIDVM_SHIM_PROBE_EXEC=1` 與 `DROIDVM_SHIM_PARCEL_MB=0`、log 檔名），tap / MAC / socket /
  disk / name 全不動（diff 見 `perf/run/4-launcher-diff.txt`）。Windows 走 `windows.sock` 的手動
  launcher；本輪證據裡沒有它的 launcher 檔，pseudo-unprotected 是靠 crosvm log 的簽名認的
  （`GH-SHIM window`、`GUNYAH-SHARE-BLOB`、LEND 只有 4 MB + 2 MB）。
- **工具**：host baseline 是 Android toybox
  `dd if=/dev/block/sdg of=/dev/null bs=1M count=2000`，每跑一次先 `echo 3 > drop_caches; sync`，
  **buffered（不是 O_DIRECT）**、唯讀、沒有任何 VM 在跑。guest 的 dd 是 uutils coreutils 0.8.0，
  同樣 buffered + drop_caches（它的 `iflag=direct` 在 4k/128k/512k/1M 全部直接回
  `IO error: Invalid input`，是 guest 工具的 bug，不是透傳問題），所以 O_DIRECT 的數字一律來自 fio：
  `fio --name=<n> --filename=/dev/sda --readonly --direct=1 --ioengine=libaio --runtime=15
  --time_based --size=8G --output-format=terse`，四組參數 `--rw=read --bs=1M --iodepth=1`、
  `--rw=read --bs=1M --iodepth=8`、`--rw=randread --bs=4k --iodepth=1`、
  `--rw=randread --bs=4k --iodepth=32`。
- **單位**：toybox dd 印的 `M/s` 是 MiB/s，uutils dd 印的 `MB/s` 是 10^6 B/s，fio terse 第 7 欄是
  KiB/s——差 4.9%，是個陷阱。下表全部換算成十進位 MB/s（bytes ÷ dd 自己量的 elapsed）。
- **Watchdog**：monitor 從 13:07:53 跑到 13:35:00（310 個 5 秒取樣），`HOST_REBOOT` = 0，host uptime
  單調從 1703 s 升到 3331 s——**整輪沒有 host reboot**。三次 VM 週期的 hugepage pool 轉換都對得上
  （3072/0 ↔ 1024/2048），收尾 `pool_avail=3072 served=0 active_vms=0`、crosvm 0 個、`2-1.1:1.0` 回到
  `uas`、`sdg` 回來、vold 重掛、兩條 tap 都不存在。

| | dd 1 MiB 循序讀 | fio 1 MiB qd1 | fio 1 MiB qd8 | fio 4K 隨機 qd1 | fio 4K 隨機 qd32 | 期間 crosvm CPU |
|---|---|---|---|---|---|---|
| host baseline（`sdg`，uas，無 VM） | 370.3 MB/s | 未測 | 未測 | 未測 | 未測 | — |
| Linux protected（without-firmware，`--swiotlb 256`） | 234 MB/s | 233.9 MB/s | 388.7 MB/s | 1195 IOPS | 9099 IOPS | 101.2%（/800%） |
| Linux pseudo-unprotected | 264 MB/s | 263.8 MB/s | 385.5 MB/s | 1330 IOPS | 9791 IOPS | 95.2%（/800%） |
| Windows pseudo-unprotected | FAILED | FAILED | FAILED | FAILED | FAILED | n/a |

Windows 整列 FAILED 的理由是同一個：磁碟從頭到尾沒列舉出來（`Get-Disk` 只看得到 VirtIO 系統碟，
沒有任何 PhysicalDrive），因為 crosvm 的 Configure Endpoint 被 `bad stream context type: 0` 打回、
xHCI 的事件處理器當場被拆掉，一個測項都沒跑到（見下面那條缺陷）。

數字的細節：host 的五次 1M 是 273.0（冷、首次觸碰，排除）、370.3、367.0、373.6、371.3，run2–5 平均
370.5；另外 bs=4M×500 = 369.0、bs=128k×8000 = 305.0。Linux protected 的兩次 1M 是 229 / 234，
4M 254、128k 218。Linux pseudo 的四次 1M 是 258 / 264 / 267 / 267（平均 264.2），4M 279、
128k 194 / 211 / 193。128k 那欄兩邊都噪（193–218），不要當成回歸讀。CPU 是 8 個取樣（每 2 秒）的平均
（protected 80.7…115、pseudo 78.5…102）；per-thread 兩邊各只有一張快照：protected `xhci` 32.0% /
`vcpu0` 38.0%，pseudo `xhci` 37.5% / `vcpu0` 29.0%。protected 的 crosvm RES 是 4.0 G、pseudo 是 8.0 G。
兩邊的 host log 六個看守樣式（`backend rejected transfer` / `endpoint is stalled` / `failed to cancel` /
`inconsistant state` / `controller stopped` / `lent memory`）全部 0；唯一雜訊是列舉時的
`transfer ring slot_1 ep_7 is already stopped` 和結束時的 `device detached from port 9`。

**解讀：**
- 佇列深度一補上，SSD 的全速就回來了：qd8 兩種模式都是 385–389 MB/s，比 host 自己 qd1 的 dd（370）
  還高一點，代表透傳路徑的**頻寬**不是瓶頸，裝置才是。
- 單佇列掉掉的是**每筆請求穿過模型的來回延遲**：一條 transfer ring 一次只有一個 URB 在途
  （ring buffer controller 要等完成才 dequeue 下一個 TD），qd1 的 fio 平均延遲 3.30 ms / 1 MiB
  ≈ 303 MB/s 的天花板，實測 233.9 / 263.8 就落在這條線下面。
- protected 與 pseudo 的差（dd 234 vs 264、fio qd1 233.9 vs 263.8）約 11–13%，那就是 swiotlb 反彈的
  成本：pseudo 整段 RAM 是 shared、沒有 `--swiotlb`，protected 每一筆都得在 256 MiB 的 restricted pool
  進出一次。qd8 沒有這個差（388.7 vs 385.5），因為那時瓶頸已經在裝置身上。
- 4K 隨機是同一個形狀：qd1 1195 / 1330 IOPS（平均延遲 616 / 549 µs），qd32 9099 / 9791 IOPS。
- CPU 大約就是**一顆核心**（101.2% / 95.2% of 800%），`xhci` thread 佔三分之一上下，其餘是 vcpu 的
  exit 處理。§5 的 R8「USB3 儲存估計 CPU 綁定在幾百 MB/s」成立。
- 唯一沒法從資料切開的：fio `--size=8G --time_based` 每輪都重讀同一段 8 GiB，qd8 超過 host qd1 這件事
  既可能是佇列變深、也可能是外接盒/SSD 自己的快取，證據分不出來。

**新缺陷（`11c5462` 仍在，待修）：Windows 的 UASPStor 要 USB 3.0 bulk streams，crosvm 的
Configure Endpoint 直接拒收，整台 xHCI 就死了。**
- 現象：13:29:40.360 `usb_hub: backend attached to port 9`，33 ms 後
  `ERROR devices::utils::event_loop] removing event handler due to error: command ring TRB failed:
  failed to config endpoint: bad stream context type: 0`（全 log 就這一條）。接著是 13 次
  `Write to crcr while command ring is running` / 13 次 `xhci: stopping all device slots and resetting
  host hub`，每 ~10 秒一輪（13:29:45 到 13:31:41）——那是 Windows 的 command-ring watchdog 在重試。
  Guest 端始終只有 VirtIO 系統碟，沒有任何 PhysicalDrive。
- 根因：`device_slot.rs:876-886` 的 `create_stream_trcs()` 把主 Stream Context Array 的
  `1..1<<(max_pstreams+1)` 每一格都讀出來，**只要有一格的 SCT 不是 1（Linear）就整個 Configure Endpoint
  失敗**；Windows 給的陣列裡有 SCT=0 的格子（未用/停用的 stream，或指到 secondary array），於是回
  `BadStreamContextType(0)`。Linux 的 uas 沒事，是因為它把每一格都填成 Linear。
- 第二層傷害：這個錯誤是從 command ring 的 handler 一路往外丟到 `event_loop`，`event_loop` 的處理方式是
  **把整個事件處理器移除**，之後這台 xHCI 對 guest 就是死的。乾淨 detach + 再 attach 一次驗證過：
  13:32:14 有 `backend attached to port 9`，之後到 VM 關機為止**沒有任何 xHCI 流量**——處理器一旦拆掉，
  這台 VM 的生命週期內就回不來了。guest 造成的 context 錯誤本來就該回一個 completion code 給
  command ring（讓 guest 自己處理），不該拆事件處理器。
- 附帶：兩份 Linux crosvm log 在 attach **之前**也各有一條同樣的
  `Write to crcr while command ring is running` 加兩條 `stopping all device slots`（13:11:05 / 13:23:43），
  是開機期的，之後列舉正常，不影響上面的數字，但那是同一個字串。

