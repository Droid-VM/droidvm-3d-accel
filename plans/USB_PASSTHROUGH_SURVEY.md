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
4. 回歸：unprotected VM 照常；pseudo-unprotected + Windows 有 USB；protected + Windows 預設無 xHCI。

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

