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
- **rig 註記（2026-09-06 補）**：5568 的 Type-C OTG 連結在同一輪測試裡掉了兩次，整棵 USB 樹跟著消失
  （dmesg `[LENOVO_UCSI] cur_role = HOST, new_role = NONE, present = [0 0]`、
  `xhci-hcd xhci-hcd.1.auto: USB bus 1/2 deregistered`，`/sys/bus/usb/devices` 全空、
  `dumpsys usb` `host_connected=false`）。第一次從 host uptime 463 s 到 1633 s（約 19.5 分鐘），起 app
  daemon 時整棵樹自己回來；第二次在 18:44 又掉一次、幾秒後自行重新列舉（devnum 全換）。全程沒有碰硬體，
  也沒有動 `msm-dwc3` 的 `mode` 開關。跑實機測試時要把這種消失和 crosvm 的問題分開看（§9.1 的 WS3a 就是
  被它作廢的）。
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

**§9.3 量吞吐量時測出的 UAS streams 缺陷（當時的 `11c5462` 上必現）：已由 crosvm `b6c9027` + `baf456e`
+ `ce5a1d2` 三個 commit 修好，並在 5568 上實測通過——Windows 認到磁碟也跑出吞吐量，Linux 無回歸。**
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
- 修法一（`b6c9027`）：SCT=0（Not Valid）是規範保留給「未使用的格子」的值（xHCI 1.2 6.2.4.1 Table 6-13），
  Configure Endpoint 照 4.6.6 只驗 Input Context 的欄位、根本不該走 Stream Context Array，Stream Context
  是在該 stream 變成端點的 current stream 時才讀（4.12.1.1），Not Valid 是**用的時候**才算錯。所以：
  stream ring 改成 `Vec<Option<…>>`（index = stream id − 1，`None` = Not Valid），主陣列一次讀一格 16 B
  的 Stream Context（不再一口氣讀固定 16 格的陣列，MaxPStreams=1 的 64 B 陣列落在頁尾也不會越讀），
  SCT 2–7（secondary array）warn 後當 Not Valid。guest 造成的 Input Context 錯誤一律回 completion code：
  MaxPStreams 超過 MaxPSASize／非 bulk 端點開 streams／LSA=0／EP Type 0／陣列或 Input Context 讀不到 →
  Parameter Error，host 配不出 streams → Resource Error，slot 不在 Addressed/Configured → Context State
  Error（4.6.6）；只有 host 自己的故障才回 Err，**command ring 的處理器不會再被拆掉**。doorbell 打到
  Not Valid、id 0、超出陣列或打到沒有 streams 的端點，一律忽略（4.12.2）。
- 修法二（`baf456e`）：帶 Stream ID 的 Set TR Dequeue Pointer 照 4.6.10 只改那一格 Stream Context
  （指標／DCS／SCT），**不碰 Endpoint Context 裡那個指向 Stream Context Array 的指標**——先前它把 ring
  指標寫進 Endpoint Context，之後每次 Stop/Reset Endpoint 或 halt 就把「stream context」從 transfer ring
  讀出來又寫回去、蓋掉 guest 的 TRB。guest 用 SCT=1 設一格原本 Not Valid 的 stream 就在那裡補建 ring
  （lazy init，這正是軟體初始化 stream 的方式，Windows 一次開一條）。host 端的 USBDEVFS streams 改成在
  slot reset（HCRST）、Disable Slot、以及同一個端點被重新 add 時就先釋放，否則下一次 alloc 拿到 EINVAL、
  變成 guest 永遠重試的 Resource Error。
- 修法三（`ce5a1d2`，兩份獨立審核抓到的收尾）：Configure Endpoint 改成「先驗證、再動手」——所有要 add 的
  Input Endpoint Context（EP Type、MaxPStreams、bulk-only、LSA、陣列讀不讀得到）全部檢查完，才 drop／
  複製／建 ring／配 host streams，被打回的命令不會在 Output Context 留下半套（4.6.6：失敗的命令不得改動
  Output Device Context）；Add-only 從 stream 端點改回一般 bulk 也會先釋放 host streams；Set TR Dequeue
  帶 SCT≠1 就把該 stream 的 ring 收掉，讓 Stream Context 與控制器對 Not Valid 的認知一致；
  `free_host_streams` 不再回 Err（slot 沒有 port 只 warn），不然它自己又會拆掉 command ring 處理器。
- host 單元測試 47 個全過（改版前 24），涵蓋陣列走訪的純函式、DeviceSlot fixture 的 Configure Endpoint /
  Set TR Dequeue / Stop Endpoint，以及「被拒絕的命令仍然發出 completion event」這條回歸。
- **實機驗收（2026-09-05／06 深夜，5568，手動 launcher，crosvm md5 `f8029b85…`＝`ce5a1d2`）：**
  - Windows pseudo-unprotected：attach 30 秒後 `USB\VID_152D&PID_A583\…` 認成
    `USB Attached SCSI (UAS) Mass Storage Device`（SCSIAdapter、Status OK、problem=0），`Get-Disk` 看到
    Disk 1 UNITEK 4096805658624 B、Offline / ReadOnly（attach 前先把 `NewDiskPolicy` 設成 `OfflineAll`，
    事後還原 `OnlineAll`，所以整輪沒有任何東西寫進 SSD，Get-Volume 也沒有多出磁碟區）。raw 未緩衝讀
    （`FileStream` + `FILE_FLAG_NO_BUFFERING`，`\\.\PhysicalDrive1`）2000×1 MiB 三趟
    **274.8 / 322.5 / 332.7 MB/s**，4 KiB 隨機 2000 次 **2530 IOPS**。
  - ETW（USBXHCI/USBHUB3/UCX/Kernel-PnP 兩次擷取）：命令 12/12 與 16/16 全部 completion code 1、零未配對；
    決定性的一條是 `fid_NumStaticStreams=0xF`——先前被拒收的那個 15 格 static stream 陣列被接受了——後面
    跟著 UCX 的 stream pipe 建立；stream 傳輸 10293 筆 = 1599.7 MiB。
  - detach／re-attach：detach 後 27 秒 guest 端磁碟消失、host 端驅動收回；re-attach 30 秒後 Disk 1 回來、
    15 條 stream 重建，500 MiB 讀 311 MB/s。沒有任何 Resource 警告或 `already has host streams`。
  - Linux protected 回歸（同一支 binary、同一種 launcher）：`uas` 綁上、沒有 `UAS is ignored`，buffered dd
    **326 / 344 MB/s**，fio（terse 第 7 欄是 KiB/s，換算後）seq qd1 **253 MB/s**、qd8 **429 MB/s**、
    rand4k qd1 **1458 IOPS**、qd32 **6728 IOPS**。
  - 兩邊 crosvm log：`removing event handler` / `config endpoint` / `Not Valid` / `Parameter Error` /
    `ContextStateError` / `Resource` / `failed to cancel` 全部 0，只剩 INFO 的
    `transfer ring slot_1 ep_7 stream_N is already stopped`；watchdog 242 個取樣 `HOST_REBOOT` = 0，
    兩個 guest 都是從裡面關機、crosvm 正常退出，收尾 pool 3072、host 驅動與 volume 都回來。
- **審核員留下的待追（都不致命，但沒解釋）：**
  - UAS status pipe（stream 端點 ep_7）上，每次 Stop Endpoint 到接下來的 Set TR Dequeue 中間固定卡 **4.0 秒**，
    三次都一樣，每次收尾都是一顆 URB 被取消（`0xC0000120`）——crosvm 對被 Stop Endpoint 取消的 TD 不發
    Stopped 傳輸事件；re-attach 時另外還有一段 12 秒沒有流量。結果是 `disk.sys` 起來要 6 秒（首次）／
    22 秒（re-attach），每次列舉必現。**（已定位並修好，見本節最後一條「Stop Endpoint 不回報進行中的
    TD」：ep_7 其實是 UAS 的 data-in 管線、不是 status 管線，crosvm 少的是 xHCI 1.2 4.6.9 要求的 Stopped
    傳輸事件；crosvm `dc1e0bf`＋`9293b36`＋`13242f9`，裝機驗證中。）**
  - fio rand4k qd32 6728 IOPS 比先前的 9099 低 26%（qd1 反而從 1195 升到 1458），單次取樣，待追。
  - Windows console log 開頭那個 BSOD 0x50 屬於上一輪 FAILED 的強制關機，不是本輪的。
  - 「沒有 Not Valid doorbell」在 info 等級的 log 證不出來（那幾條訊息是 `debug!`）。

**HCRST 缺陷（2026-09-05 深夜由 M4 的「VM 開機觸發」測出，`11c5462` 仍在）：HCRST 沒有重置
command ring／CRCR／interrupter，開機前就接上的裝置會讓整台 xHCI 在 guest kernel 起來之前就死掉——
已由 crosvm `391518c`（cherry-pick 自 `eb47f50`）修好，2026-09-06 凌晨在 5568 上實機驗證通過。**
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
- 修法（`391518c`）：`Xhci::reset()` 建一個 `RingBufferStopCallback`，同時交給 command ring 與所有
  transfer ring；等每一條 ring 都停妥之後一次做完——command ring 歸位（dequeue pointer 0、consumer cycle
  回初值、狀態 Stopped），CRCR／DCBAAP／CONFIG／DNCTRL 回 reset value，`Interrupter::reset()`（event ring
  回到「未初始化」、IMAN/IMOD/ERSTSZ/ERSTBA/ERDP 回初值、moderation timer 解除）——**這一步排在 slot ＋ hub
  reset 之前**，這樣 hub reset 重貼的連線變化才會乖乖等在 PORTSC 裡，而不是寫進上一個 guest 的 ERST——
  然後 slot ＋ hub reset，最後 USBSTS 設成 HCH|CNR 再把 CNR 清掉。crcr 暫存器的 `reset_value` 從 9 改成 0
  （規範預設值，那個 9 ＝ RCS|CRR 就是 CRR 從上電就是 1 的來源），寫入遮罩維持不讓 guest 設 CRR，
  CRCR 讀出來只有 CRR 一個位元（規範 5.4.5）。
- 順帶把 CRCR 的 CS/CA 補上：帶 CS 或 CA 的寫入會把 command ring 停下來、清掉 CRR、發一個完成碼 24
  （Command Ring Stopped）的 Command Completion Event——這就關掉了本節前面記的那條「命令逾時時 Linux 的
  abort 救不回來」：Linux 寫 CA 之後輪詢 CRR 五秒，CRR 永遠是 1 就會判 `Abort failed to stop command ring:
  -110` → `HC died`。
- 審核抓到、一併修掉的三件事：`event_loop.rs` 在重新上鎖前先把 handler 的 `Arc` 放掉（非同步 reset 路徑上，
  callback 跑在某條 ring 的 `on_event` 裡，slot reset 會丟掉那條 ring 的最後一個參照，drop 又回頭鎖同一把
  handlers mutex → 整個 xHCI event loop 自我死鎖）；`RingBufferController::stop` 把 ring 停成 Stopped 時
  會把先前積著的 stop callback 一起發掉（不然它們晚一步觸發，會撞上剛被重置的 event ring）；event ring
  還沒初始化時的完成事件改成 debug log 丟掉，而不是讓整台控制器 fail。
- 測試：cherry-pick 併回 stream 那三個 commit 之後，host 單元測試 51 個全過（interrupter reset、idle ring
  立刻停下並從新指標續跑、Stopping ring 的 stop callback 全數發出、event ring 未初始化時完成事件被丟棄）。
- 一併關掉的風險：`11c5462` 的延後 PORTSC 是靠「event ring 尚未初始化」判斷的，但 HCRST 之後 interrupter 還握著
  firmware 那份 event ring；kernel 自己 HCRST 時 hub reset 重貼的 port change 事件會被寫進 firmware 的 ERST
  記憶體——那塊記憶體已經歸 kernel 用了，是一條會默默弄髒 guest 記憶體的路。把 interrupter 一起重置就沒了。
- 狀態：**已修並驗證（2026-09-06 凌晨，5568；APK `0.0.6.r223.gf893906` md5 `1e7f5b95…`、
  crosvm md5 `b55fcee2…`＝`391518c`，手動 launcher 用的是同一支 binary；§9.3 那輪跑的 `f8029b85…`
  是 `ce5a1d2`，還沒帶這個修正）。**
  - **app 路徑（daemon 自動規則，M4 第三輪；情境表見 `USB_PASSTHROUGH_ANDROID_PLAN.md` §2.4）**：F（VM 開機
    觸發接兩顆）、R（`vm_reboot` 釋放再接回）、G（`vm: null` 留 host ＋ `any` 收尾）、WF（Windows
    pseudo-unprotected 開機前就掛規則）四個情境 daemon 端與 guest 端**全部 PASS**——第二輪必死的 guest 端
    這次 `lsusb` 兩顆都在、`/dev/video0,1`、asound card 1+2，`v4l2-ctl` 抓 30 幀 rc=0、`arecord` 錄到
    64044 B，dmesg `HC died`＝0。firmware 階段從壞掉時的 ~23 秒回到 **3.28 s（F）／3.30 s（R）／3.01 s（G）**，
    `Write to crcr`／`invalid guest address`／`removing event handler`／`controller stopped` 全部 0。
  - WF 是同一件事的 Windows 版（VM 開機時裝置已經掛在 port 上）：`host controller reset`＝2
    （17:10:42.844 firmware、17:10:47.570 Windows 的 xhci 驅動），`backend attached`＝1、required-zero 全 0、
    ERROR＝0，Windows PnP 認到攝影機 `ConfigManagerErrorCode`＝0；`vm_stop` 後 +0.36 s 釋放，host 的 1-1.3
    1 秒內回到 uvcvideo。
  - **WU1（手動 launcher，Windows pseudo-unprotected ＋ UNITEK UAS）**：PnP 認成
    `USB Attached SCSI (UAS) Mass Storage Device`（problem=0），`Get-Disk` Disk 1 UNITEK 4 TB
    Offline／ReadOnly，raw 未緩衝讀 500×1 MiB 兩趟 **347.1 / 361.2 MB/s**；required-zero 計數全 0，而且
    **`Write to crcr` 的 ERROR 不見了**（run1 的 `f8029b85` 有 1 條）、**一條
    `stream_N is already stopped` 都沒有**（run1 有 77 條）。
  - **WU2（「帶著磁碟暖開機」）——先講怎麼跑的**：手動 launcher 下真正的 guest 暖開機測不到，因為
    `shutdown /r` 會讓 crosvm 程序自己結束（`VmEventType::Reset` → `ExitState::Reset`，
    `src/crosvm/sys/linux.rs:4650`／`src/main.rs:128` 印 `exiting with reset`，而 `run_windows.sh` 只
    `exec` crosvm 一次、沒有東西會重啟它），所以 WU2 改用兩種手法在同一個 crosvm pid（11818）上做出同樣的
    xHCI 條件：(a) 讓 VM **帶著裝置開機**——crosvm 17:32:19 起，UNITEK 在 12 秒後的 17:32:31 就 attach，
    Windows 的 USBXHCI 是對著一個已經連著裝置的 port 起來的（17:32:32.882 那次 HCRST）；(b) 在磁碟已經跑過
    全速讀、UAS bulk streams 都配好之後，在 guest 裡用
    `pnputil /restart-device "PCI\VEN_1B36&DEV_000D…&0&20"`（Standard USB 3.0 eXtensible Host Controller）
    **重啟 xHCI 兩次**（17:35:00.978、17:36:11.959；這台 Windows 沒有 `Restart-PnpDevice` 這個 cmdlet，
    所以用 pnputil）。
  - **WU2 結果**：三次帶著裝置的 HCRST 之後 Windows 每次都重新列舉（`USB\VID_152D&PID_A583` Status=OK
    problem=0）、Disk 1 仍是 Offline／ReadOnly、沒有多出磁碟區，raw 讀分別是**帶著裝置開機後 294.0 / 301.3
    MB/s、第一次 HCRST 後 304.6 / 302.5 MB/s、第二次後 300.7 MB/s**。每一次都是
    `resetting all device slots and the host hub` 接著
    `port 9 changed before the guest set up its event ring; the change waits in PORTSC`——新的 HCRST 路徑
    把 port change 留在 PORTSC，而不是丟掉或寫進已經死掉的 event ring。計數 `Resource`＝0、
    `already has host streams`＝0（代表舊的 host streams 確實被釋放、新的配得出來），其餘 required-zero
    全 0、ERROR＝0、WARN＝2（都是與 USB 無關的 gunyah 開機提示）。整份 Windows log 共 **5 次
    `host controller reset`**，第 5 次是 17:43:13.517 關機時 Windows 自己拆掉 xHCI，那時裝置早在 17:37:41
    detach、上面沒有任何裝置，接著就是 `crosvm exiting with success`。
  - Linux 這邊同一支 binary 重跑（LU1）：`uas` 綁上、沒有 `UAS is ignored`，log 57 行 ERROR＝0、
    `is already stopped` 0 條（run1 是 1 條 ERROR ＋ 77 條），吞吐量見 §9.3。

**Stop Endpoint 不回報進行中的 TD（沒有 Stopped transfer event），Windows 每次 stop 固定等 2–4 秒——
已由 crosvm `dc1e0bf` + `9293b36` + `13242f9` + `e5eece2` + `f96fd65` + `d849baf` + `2a8e371` 七個 commit
修好：Windows 每次 stop 的 4 秒／2 秒收斂到 5 ms 以內、Linux 的 isochronous 回歸歸零、stream 端點的
duplicate Stopped 歸零、被默默倒回的那條 stream ring 會跟著一起重啟，最後再把「整顆 TD 其實已經送達卻被
當成停止」的資料遺失競態拆掉。前六個 commit 都在 5568 上實機驗到（run4、run5、run6、run7 的 Windows／
Linux／app 三條路徑）；最後那一個（`2a8e371`）只有單元測試與無回歸驗證——run7 的 12 次 attach 裡那個競態
一次都沒有再出現，所以它是「證明沒有回歸」，不是「證明治好了」。**
- 現象（ETW，scratchpad `m6b/uas/run1` 的 `4W2-etw.txt`、`usbtrace-w*.xml`）：三個週期一模一樣——UAS
  data-in stream 端點（slot 1 DCI 7）的 Stop Endpoint 在 1 ms 內就拿到 completion code 1，接下來
  **4.008／4.015／4.000 秒**之內沒有任何 USBXHCI／UCX／USBHUB3 事件，等滿了才是 Set TR Dequeue，
  收尾都是一顆 URB 以 `0xC0000120`（STATUS_CANCELLED）完成。同一種等待在別的端點型態上是 **2.0 秒**，
  每一次 Stop Endpoint 都付：windows3 的音效 ISO DCI 6（02:32:29.432 → 02:32:31.440，同一輪另有三次）、
  windows4 的音效 DCI 7（07:16:31.839 → 07:16:33.855）、windows5 的攝影機 interrupt DCI 3
  （08:55:22.685 → 08:55:24.688）與攝影機 ISO DCI 11（08:58:56.333 → 08:58:58.350）。`disk.sys` 起來
  因此是 6.0 秒（首次）／22.0 秒（re-attach），22 秒那次中間還有一段 **12 秒完全沒有流量**：一顆其實
  已經完成的 TD 被回報成「什麼都沒有」，Windows 當它沒跑過、重新排上 ring，crosvm 就對裝置早就答完的
  命令再送一顆 bulk IN，一直卡到 UASPStor 的請求計時器逾時發 ABORT TASK。
- 根因：crosvm 的 Stop Endpoint 把該端點（所有 stream）在飛的 URB 全部 DISCARDURB 掉，reap 回來不管
  什麼狀態一律當成 Cancelled、只叫醒 ring，**不發任何 Transfer Event**；寫回 Endpoint／Stream Context 的
  TR Dequeue Pointer 又是 `trc.stop()` **之前**讀的，那時 ring 早就走過整顆 TD，指標落在下一顆 TD 上。
  xHCI 1.2 4.6.9 要求 xHC 對「進行中的那顆 TD」發一個 Stopped／Stopped - Length Invalid／Stopped -
  Short Packet 的 Transfer Event，而且要排在 Stop Endpoint 的 Command Completion **之前**，指標寫的是
  那顆 TRB 本身；Windows 的 USBXHCI 等的就是這個事件，等不到就靠 watchdog 收尾（bulk／interrupt／
  isochronous 2 秒、stream 端點 4 秒），自己把 URB 判成 STATUS_CANCELLED、自己重指 ring。順帶更正上面
  那條待追的說法：**DCI 7（ep_7）是 UAS 的 data-in 管線，不是 status 管線**——DCI 5 的 5149 筆全是
  1024 B 的 Sense IU、DCI 2 的 5147 筆全是 32 B 的 Command IU，DCI 7 走的是 524288 B 的讀與 INQUIRY／
  READ CAPACITY／MODE SENSE 的資料。
- 修法一（`dc1e0bf`）：**搶在 cancel 之前完成的傳輸要保住它的完成。** DISCARDURB 打到已經完成的 URB 會
  拿到 EINVAL，那顆 URB 是帶著真實狀態與資料被 reap 回來的；`update_transfer_state` 改成只有 kernel 真的
  解掉（-ENOENT）才算 Cancelled，其他狀態一律 Completed、走原本的 Success／Short Packet／Stall／NoDevice
  路徑並帶 `actual_length`。Cancelled 這條也改成拿到真正搬過的位元組數（IN 方向先把資料抄進 guest
  buffer），後面那個 Stopped 事件才報得出正確的 residual。光這一條就把那 12 秒拿掉。
- 修法二（`9293b36`）：**Stop Endpoint 回報進行中的 TD，並把 ring 留在它身上。** 被 cancel 的 TD 由
  `XhciTransferManager` 記下「第一顆沒有整顆搬完的 data TRB」（就是進行中的那顆）、它的 residual
  （6.4.2.1）、TD 的第一顆 TRB 與那顆 TRB 的 cycle bit；發 Stopped(26)，沒有帶資料的 TRB（只有 Event
  Data／No-op）就發新加的 Stopped - Length Invalid(27)、長度 0，一律 ED=0 指向 transfer TRB
  （4.11.5.2）。新的 `TransferDescriptorHandler::finish_stop` 由 `RingBufferController::on_event` 的
  Stopping 分支在**狀態轉 Stopped、stop callback 釋放之前**呼叫，發事件並把 ring 的 dequeue pointer／
  consumer cycle 倒回那顆 TRB——Command Completion 就是 stop callback 最後一份被 drop 的時候，事件因此
  自然排在完成之前。Endpoint／Stream Context 的指標與 DCS 改由 stop callback 的 closure 寫（它看到的是
  倒回後的 ring），握著那顆 TD 的 stream 另外寫 Stopped EDTLA（6.2.4.1），其餘各格維持 guest 原本的值。
  dequeue_all（isochronous）的 ring 只對最早那顆沒完成的 TD 發一個 Stopped、倒回它，排在後面已經交出去的
  TD 就留在 ring 上；stream 端點則是每條有 TD 在飛的 stream 各一個。halt 與 Reset Endpoint 不倒回也不發
  Stopped（StallError 早就送過了）。
- 修法三（`13242f9`，兩份獨立審查的收尾）：(a) **must-fix**——stop 期間 reap 到 -ENODEV 會卡死整條
  command ring（NoDevice 分支 detach 完就 return、沒有叫醒 ring，Stopping 的 ring 永遠不 park，
  Stop Endpoint 的完成與排在後面的每一顆命令都出不去，連斷線的 Disable Slot 也是），改成 detach 之前
  先送出 transfer completion event；(b) `stop()` 的同步 park 分支也要跑 finish_stop（與 Stopping 分支
  共用 `finish_stop_and_park`），否則 reap 搶先跑完那次 stop 就既沒事件也沒倒回；(c) 已經在 Stopping 的
  ring 再被 stop 一次改成「併入正在進行的那次」，不再重發 cancel（重發的第一件事就是把記錄清掉）；
  (d) Set TR Dequeue 會清掉舊的 stopped 記錄（軟體移動 ring 就代表那個位置作廢，否則下一次 stop 會拿
  陳舊的 EDTLA 蓋掉 guest 的值）；(e) EDTLA 的走訪不再把 SetupStage 當成帶資料的 TRB（4.11.5.2）；
  (f) `update_transfer_state` 的狀態檢查補回來（只接受 Cancelling／Submitted，其餘回
  BadXhciTransferState）。
- 測試：host 單元測試 **66 個全過**（`391518c` 是 51、`dc1e0bf` 52、`9293b36` 62），clippy 回到
  `391518c` 的 39 個 warning 基準。新加的是 `a_transfer_reaped_complete_after_its_cancel_is_completed`
  （backend/utils）、`cancelled_td_reports_stopped_at_the_trb_in_progress`／
  `a_cancelled_td_without_data_trbs_is_stopped_length_invalid`／
  `the_earliest_cancelled_transfer_is_the_one_the_ring_stops_at`（xhci_transfer）、
  `stop_with_a_transfer_in_flight_rewinds_to_it_and_reports_before_the_callback`（順序向量必須是
  `["stopped", "callback"]`）／`stop_of_a_drained_ring_rewinds_to_the_earliest_unfinished_descriptor`／
  `halt_does_not_rewind`（ring_buffer_controller）、
  `finish_stop_reports_the_earliest_cancelled_descriptor_and_leaves_the_ring_at_it`
  （transfer_ring_controller）、`stop_endpoint_writes_the_context_from_the_ring_the_callback_sees`／
  `stop_endpoint_without_streams_writes_the_ring_position_at_the_completion`／
  `stream_context_write_back_sets_the_stopped_edtla_of_a_stopped_stream_only`（device_slot），以及
  `13242f9` 的 `a_no_device_completion_still_signals_the_ring`／
  `stop_that_finds_the_ring_already_quiet_still_reports_the_stopped_descriptor`／
  `a_second_stop_while_stopping_does_not_cancel_again`／`moving_the_ring_clears_the_stopped_record`。
  in-tree 沒有假的 `XhciBackendDevice`（只有 host 與 fido 兩個後端），所以「Stopped 真的排在 Command
  Completion 之前」這一條只能靠實機驗。
- 狀態：**Windows 實機通過、Linux 掉出一個新回歸**（2026-09-06，5568，crosvm md5
  `9ccc9856…`＝`13242f9`，兩邊都是手動 launcher，不經 app）。證據在 scratchpad `m6b/uas/run3`
  （Windows `w3WS1*`／`w4WS2*`／`w5WS3*`／`w6-*`／`w7-final.txt`，Linux `l*.txt`，兩支 `monitor-*.log`）。
  ETW 的每一段間隔都由第三方稽核用自己寫的 TRB 解碼器（Stop Endpoint ＝ TRB type `0x0F`、Set TR Dequeue
  ＝ `0x10`，取 dword3 的 bits 15:10，比對 submit／completion 時遮掉 cycle bit）從原始 timeline 重算一次，
  與跑測那份**到 1 ms 內完全一致**。Windows（pseudo-unprotected）這一輪的每一次 Stop Endpoint：

| 情境（端點） | → Command Completion | → Set TR Dequeue | 修好之前 |
|---|---|---|---|
| WS1 UAS 第一次 attach（slot 1 ep_7 data-in stream） | 1 ms | 1 ms | 4009／4015／4002 ms |
| WS2 detach → re-attach（slot 1 ep_7） | 0 ms | 0 ms | 同上 |
| WS3b 音效 isochronous OUT（slot 1 ep_6） | 1 ms | 1 ms | 2008 ms |
| WS3b 攝影機 interrupt IN（slot 2 ep_3） | 1 ms | 1 ms | 2003 ms |

  （右欄的 media 基準是 windows3／4／5 三輪 **26 次** pre-fix stop，每一次都落在 1990–2065 ms。）

- Windows 其餘量測：被 cancel 的 TD 現在都在 stop 之後 **1 ms 內**以 `0xC0000120` 收掉（整輪 12 顆），
  不用再等 Windows 的 watchdog——`Kernel-PnP 902 WatchdogTriggered` 因此 **0 次**（修好之前必現），
  `disk.sys` 的 DeviceStart 是 **16 ms**（首次 attach）／**1984 ms**（re-attach），對上修好之前的
  6003／22044 ms；`etw_decode` anomalies＝0、`USBXHCI 34`＝0。功能面全部正常：raw 未緩衝讀
  `\\.\PhysicalDrive1` **290.4／289.2／303.8 MB/s**（磁碟全程 Offline／ReadOnly，attach 前先把
  `NewDiskPolicy` 設成 `OfflineAll`、收尾還原 `OnlineAll`）；`PlaySync` ×3 **5306／5234 ms**
  （基準 5.2–5.4 s，沒有變差）；攝影機拍照 118291 B、6 秒錄影 928947 B。
- **WS3a 那一輪作廢，原因在治具不在 crosvm**：18:44:02–18:44:10 手機的 Type-C 掉了整棵 USB 樹
  （見 §4 的 rig 註記），crosvm 在那兩次 stop 之後 0.4 秒就對 usbfs fd 拿到 `ENODEV`、reap 不回被 cancel
  的 URB，也就發不出 Stopped 事件，Windows 退回自己的 2 秒計時器（2016／2011 ms）——注意那兩次的
  Command Completion 仍然是 0／1 ms，等的只有 Set TR Dequeue。同一組情境在 WS3b 重跑就是上表的 1 ms。
  「host 裝置節點在 stop 途中消失」這條路徑本來就不在這次改動的範圍內。
- Linux（protected-without-firmware，`--swiotlb 256`）同一支 binary 全程重跑：音效 `speaker-test` rc=0、
  零 xrun；攝影機自帶 mic `arecord` rc=0、64044 B（裝置談成自己原生的 16 kHz，正好 2 s×16000×2 B ＋ 44 B
  header）；攝影機 3×60 幀 × 兩種格式 **6/6 rc=0**；UAS 綁上 `uas`。吞吐量 dd **226／251 MB/s**
  （1000×1 MiB）與 **214／233 MB/s**（2000×1 MiB）——看起來比 §9.3 的 315／321 低，於是當場把前一支
  binary（`b55fcee`）裝回去、用同一份腳本在同一小時內重量，得到 **230／221 MB/s**（fio 兩支差不到 10%），
  **不是回歸**：run2 那組數字今天在產生它的那支 binary 上也重現不出來（機身 33–36 °C，不是熱節流）。
  `failed to cancel` **0 條**（修好之前的 linux2 那輪是 62 條）。log 裡剩下的 3 條 ERROR 全是
  `device slot is already enabled`，在 `b55fcee` 上 attach 第 2／第 3 顆裝置照樣一模一樣重現，是既有問題。
- **run3 掉出的 isochronous 回歸（已由 `e5eece2` 修好）：drain 過的 ring 停下來時，把「搶在 cancel 之前
  落地」的每一顆 TD 都當成正常完成回報。** guest 印了 **119** 條 `xhci_hcd ... Event dma <X> for ep 4
  status 13 not part of TD at <Y> - <Y>`（`ep 4` ＝ ep_index 4 ＝ DCI 5 ＝ UVC 的 isochronous video IN），
  分成 6 陣、每次串流停止一陣。**先更正上一版的判讀：status 13 是 `COMP_SHORT_PACKET`，不是
  `COMP_STOPPED`（26）**——這一條正好證明那 119 條不可能來自 Stopped 的發送路徑（`finish_stop` 一次 stop
  最多發一個，6 次 stop 最多 6 個，crosvm 那邊本來就是一次一個），只能來自 `dc1e0bf`「搶在 cancel 之前
  完成的傳輸要保住它的完成」那條規則：dequeue_all 的 ring 一次交給後端上百顆（最多 256 顆）單 packet 的
  isochronous URB，而 isochronous URB 是服務週期一到就完成，不管 guest 還要不要那一幀，所以 Stop Endpoint
  的 `USBDEVFS_DISCARDURB` 多半打在已經落地的 URB 上（usbfs 回 EINVAL，URB 帶著真實狀態 0 被 reap 回來），
  `update_transfer_state` 於是把每一顆都轉成 Completed、各發一個普通的 Short Packet Transfer Event——而
  guest 早就把這些 TD 全部 unlink 掉了，每一條事件都落在它還在等的那顆 TD 前面。
- 修法四（`e5eece2`）：**drain 過（`dequeue_all`）的 ring 上，被 cancel 的傳輸不管 reap 回什麼狀態
  （NoDevice 除外）都併進那唯一一個 Stopped 事件。** `update_transfer_state` 多一條帶閘門的分支：ring 是
  drained-ahead 時，(任何狀態, Cancelling) → Cancelled，照原本那條安靜的 `record_stopped` 路走，ring park
  之後由 `finish_stop` 對最早那顆發唯一一個 Stopped／Stopped - Length Invalid 並倒回它；裝置真的搬過的
  位元組仍然靠 Cancelled 分支的 buffer 複製與事件的 residual 送進 guest。NoDevice 留在自己的分支，裝置
  中途被拔掉時 port 照樣 detach。閘門是新拉的一條線：`RingBufferController::set_dequeue_all` →
  `TransferDescriptorHandler::set_drained_ahead`（預設 no-op）→ `XhciTransferManager` 的旗標 →
  `XhciTransfer::on_drained_ahead_ring()`；沒有 dequeue_all 的 ring（bulk／interrupt／control／stream）
  一個 bit 都沒動。host 單元測試 **69 個全過**（`13242f9` 的 66 ＋ 3，含審查回合補的那個把
  `set_dequeue_all` 從 controller 一路走到 transfer manager 的鏈路測試——把中間那個轉呼叫拿掉就會紅）。
  審查接受的一條偏離：drain 過的 ring 上，一顆在 cancel 送出之後才完成的 TD 不再保有自己的完成事件，
  而是併進那個 Stopped（搬過的量走 residual）——guest 本來就已經 unlink 它了，那 119 條警告就是這些
  完成事件本身。
- **2026-09-06 驗收（run4，5568，crosvm `e5eece2` md5 `9f5365c2…`，證據在 scratchpad `m6b/uas/run4`）：
  Linux A／B 直接歸零、Windows 每次 stop 都在 5 ms 以內、app 路徑同樣乾淨。**
  - Linux（手動 launcher，同一份工作量腳本、同一個十分鐘窗口內跑兩趟）：新 binary 6 次攝影機串流停止
    **0 條** `not part of TD`；把前一支 `13242f9`（md5 `9ccc985…`）裝回去跑同一份工作量得到 **131 條**
    （6 陣、每次 stop 一陣），治具照樣重現得出來，那個 0 是真的不是漏跑。fps 兩支一模一樣（v4l2 回報的
    **15.0**）；run3 那組 19–20 fps 今天在哪一支 binary 上都沒重現，因此不歸給任何一支。其餘照舊：攝影機
    自帶 mic `arecord` **192044 B**、`speaker-test` rc=0、UAS dd **234／229 MB/s**。
  - Windows（pseudo-unprotected，ETW；27 次 Stop Endpoint 由第三方稽核用自己的 TRB 解碼器從原始 timeline
    重算，加上 app 那一輪的 1 次共 28 次，每一次的 completion 與 Set TR Dequeue 間隔相同）：

| 情境（端點） | 次數 | → Command Completion／Set TR Dequeue |
|---|---|---|
| 攝影機 interrupt IN（slot 1 ep_3；正常停止／殺行程／殺 Frame Server／PnP disable） | 10 | 0–5 ms |
| 音效 isochronous OUT（slot 2 ep_6；含 kill audiodg 真正打斷 drain 過的 ring 的 6 顆 URB 中止） | 6 | 1–2 ms |
| UAS stream 端點（slot 1 ep_7，10 個 attach／detach 週期） | 11 | 0–1 ms |
| app 那一輪的 Windows VM（slot 1 ep_3） | 1 | 0 ms |

  - `Kernel-PnP 902 WatchdogTriggered` 這一輪 **1 次**，就是下一條的 stream 缺陷。**攝影機的 VIDEO
    isochronous IN 端點在 Windows 上從頭到尾收不到 Stop Endpoint**：四條收尾路徑（正常停止、殺掉錄影
    行程、殺掉 Frame Server、錄影中途 PnP disable）都試過，Windows 一律讓那條 ring 自己 drain 完再用
    Configure Endpoint alt=0 拆掉，所以這條路徑只能在 Linux 上驗（上面 A／B 驗的就是它）。
  - App 路徑（APK md5 `39a9d2f9…`，裡面的 crosvm 就是 `9f5365c…`，裝在 5568）：Ubuntu VM-start trigger
    在 `running` 之後 **9.3／9.5 秒**把兩顆裝置接上，guest 攝影機 3×60 幀、`not part of TD` **0 條**、
    mic **64044 B**、`speaker-test` rc=0，`vm_stop` 時歸還；Windows app VM 預先接上攝影機：PnP 全 OK、
    拍照 **182153 B**、錄影 **931222 B**，那一輪唯一的一次 Stop Endpoint 是 **0 ms**。當天 watchdog
    `HOST_REBOOT` **0**、OTG 掉線 **0**。
- **修法五（`f96fd65`，設計 `plans/crosvm-xhci-designs/DESIGN-STOPPED-STREAMS.md`）：一次 Stop Endpoint 在所有
  stream ring 之間只發一個 Stopped 事件。** 機制（run4 抓到的那個新缺陷）：每條 stream ring 各是一個完整的
  `RingBufferController`，它的 handler 各自擁有一份 `XhciTransferManager`，`record_stopped`／`take_stopped`
  的去重因此是**每條 ring 一份、跨不了 ring**——UAS 冷接上那次，第一個 Stop Endpoint 時有 **兩條 stream** 各有
  一顆 TD 在飛（stream 3 那顆是與 Stop Endpoint **同一毫秒**才排上 ring 的，crosvm 處理停止時它已經送出 URB），
  兩條 ring 就各報了自己那顆被 cancel 的 TD、各發一個 Stopped；Windows USBXHCI 在同一毫秒記下 event 30
  `Received duplicate Stopped Transfer Events`（`HWVerifierFlag=0x2000000`）、丟掉第二個，它報的那顆 URB 被晾了
  **16.28 秒**，`disk.sys` 的 DeviceStart 拖到 **18.77 秒**。規範是：有 stream 的端點只有一條 current stream，
  一次 Stop Endpoint 只發**一個** Stopped 事件（xHCI 1.2 4.12.1.1、4.6.9）。修法：同一個命令的所有 ring 共用
  一份認領（`Arc<AtomicBool>`）——`stop_endpoint` 的 stream 分支在停下每條有內容的 ring 之前先把同一份認領裝
  上去，第一條「帶著被 cancel 的 TD」把 stop 收完的 ring 以 compare_exchange 拿走認領並發事件，其餘同樣有被
  cancel 的 TD 的 ring **照樣默默倒回**（`StoppedTd` 多一個 `reported` 旗標），Stream Context 的 TR Dequeue
  Pointer 與 DCS 照寫回去，但不發事件、也不動 guest 的 Stopped EDTLA；沒有東西被 cancel 的 ring 不消耗認領，
  所以「搶在 cancel 之前完成」的那條 stream 保有自己原本的完成事件，而該發的 Stopped 仍然發得出去。認領隨這次
  stop 被取走、或被下一次 start 丟掉，不會活過自己的命令；沒有 stream 的端點不裝認領，drained-ahead
  （isochronous）閘門、halt、Reset Endpoint、HCRST 都沒動。審查回合補一條：Stop Endpoint 打在**不是 Running**
  的端點上要回 Context State Error（4.6.9，比照 `reset_endpoint` 的 Halted 守衛），否則一個違規的、在前一次還
  沒完成就送出的第二次 Stop Endpoint 會對還在 Stopping 的 ring 重裝一份新認領、再發一個 Stopped（Windows／
  Linux 都把命令排在自己的完成之後，實際走不到）。host 單元測試 **77 個全過**（`e5eece2` 的 69 ＋ 8）。
- Watchdog／收尾：兩支 monitor（Windows 段 18:28–18:58、Linux 段 19:03–19:32）`HOST_REBOOT` 都是 **0**、
  host uptime 單調上升；每次 launch 前 `PRECHECK_OK`、launch 後 `POSTLAUNCH_OK served=2048`；每個 guest
  都是從裡面關機、crosvm 自己在 10 秒內退出（沒有 `crosvm stop`、沒有 kill），pool 收回 **3072**、
  `served=0 active_vms=0`，host 端三顆裝置的驅動、`sdg` 與 `public:8,98` 全部還原。
- **2026-09-06 深夜驗收（run5，5568，crosvm `f96fd65` md5 `ad81e4e4…`，同一支 binary 打包的 APK md5
  `323f35fb…` 也裝上去跑過，證據在 scratchpad `m6b/uas/run5`）：要修的那條驗證器抱怨歸零，被它蓋住的那個
  後果沒有跟著好。**
  - Windows（pseudo-unprotected，手動 launcher；3 次冷開機 attach ＋ 每台 2 次熱插拔＝9 次 attach）：USBXHCI
    event 30「duplicate Stopped」**0 次**（run4 同一情境必現），11 次 Stop Endpoint 裡有 **9 次**是兩條 stream
    都有 URB 在飛——稽核員拿 UCX 26/27 的 URB 指標配上 USBXHCI 41 的 `EndpointContextIndex`／`StreamId` 自己
    重建了一份 in-flight URB 追蹤器，證明那個競態每一次都真的踩到了。每一次 Stop Endpoint 的 completion 與
    接下來的 Set TR Dequeue 都在 **0–1 ms**（從原始 XML 重算是 0.170–0.922 ms），停滯不在 handshake 上。

| 週期 | duplicate-Stopped | Kernel-PnP 902 | `disk.sys` DeviceStart | 兩條 stream 在飛 | 被晾住的 URB |
|---|---|---|---|---|---|
| cold1 冷接 | 0 | 1（3007 ms） | 18685 ms | 是 | stream 2，**16.19 秒** |
| cold2 冷接 | 0 | 0 | 12 ms | 是 | 無 |
| cold3 冷接 | 0 | 1（3000 ms） | 16644 ms | 是 | stream 3，**16.13 秒** |
| 熱插拔 ×6 | 0 | 0 | 6–12 ms | 是 | 無 |

  - Windows 其餘量測：raw 未緩衝讀 **301–317 MB/s**（磁碟全程 Offline／ReadOnly、從頭到尾沒有掛出任何磁碟區），
    crosvm log 每個 watch pattern 都 0、ERROR **0**——被晾住的那顆 TD，crosvm 一句話都沒印。
  - Linux（protected-without-firmware）：UAS dd **334／339 MB/s**（run4 是 234／229），新加的兩條 dd 併發
    （兩條 stream ring 真的同時在飛，`inflight` 看得到 4 筆讀）**198／197 MB/s**；攝影機 6×60 幀 **15.0 fps**、
    `not part of TD` **0 條**；攝影機 mic `arecord` 192044 B、`speaker-test` rc=0。與 run4 唯一的差別是
    `f96fd65` 自己加的那條守衛：**`endpoint at index 0 is not running` ERROR ×2**（AB13X 列舉時控制端點被 STALL
    成 Halted，guest 接著去 dequeue 控制 URB，Stop Endpoint 就打在一個不是 Running 的端點上）——正是設計要的
    行為，guest 毫無反應、AB13X 照樣出聲，但那是 error! 等級的新噪音，待降級。
  - App 路徑（APK `323f35fb…`，裡面的 crosvm 就是 `ad81e4e4…`）：安裝成功；Ubuntu 場景 F（VM-start trigger）
    在 `running` 之後 **9.28／9.48 秒**把兩顆裝置接上，攝影機 3×60 幀 14.98–15.00 fps、`not part of TD` **0**、
    mic 64044 B、`speaker-test` rc=0；Windows app VM 預先接上攝影機：PnP 全 OK、拍照 177545 B／錄影 908143 B，
    ETW 的 duplicate-Stopped **0**（但這一輪只過 UVC 攝影機、沒有 stream 端點，競態沒被踩到，那個數字要看上面
    Windows 那一輪）。三段 monitor 全程 `HOST_REBOOT` **0**。
- **修法六（`d849baf`，分析 `plans/crosvm-xhci-designs/ANALYSIS-STREAM-RESTART.md`、設計
  `plans/crosvm-xhci-designs/DESIGN-STREAM-RESTART.md`）：一次 doorbell 重啟該端點的每一條有內容的
  stream ring。** run5 三份冷 trace 逐微秒重建之後，答案很乾脆：被晾住的**永遠是那條沒被報的（silent）
  ring**——cold1 報 stream 3、晾 stream 2，cold3 報 stream 2、晾 stream 3，角色剛好對調（誰的 cancel 先
  reap 回來，誰就拿走那一個 Stopped）。停止之後 Windows 的 USBXHCI 對**兩條** stream 都下 Set TR Dequeue
  （指標一字不差就是 crosvm 倒回後寫回 Stream Context 的位置，兩條都 code=1），再對那條 silent ring 發一個
  沒有相鄰 41 的**裸 45**——把它認為還掛在 ring 上的那顆 TD 重新武裝——然後只對它認定為 current 的那條
  stream 敲 doorbell。crosvm 卻只重啟 **doorbell 指名的那一條** ring（`ring_doorbell` →
  `get_trc(index, stream_id).start()`），倒回的那條再也沒有人踢，TD 就一直躺著，直到 16.1 秒後 UASPStor 的
  請求計時器逾時、第二次 Stop Endpoint 加一模一樣的 Set TR Dequeue 才把它收掉——而那次重試本身就證明重啟
  這條路是好的：同一顆 TRB 一被指名就立刻執行。規範上 doorbell 的 stream id 只是**提示**（xHCI 1.2
  4.12.2），任何一次 doorbell 都把端點帶回 Running，服務哪條 stream 由裝置的 ERDY 決定。修法：stream id
  驗過之後，該端點**每一條有內容的 stream ring 都 `start()`**——空的 ring 立刻自己 park 回去，倒回的 ring
  重新執行它那顆 TD，新的 backend URB 去把裝置還握著的資料取回來；無效或 Not Valid 的 stream id 照舊忽略、
  什麼都不啟動（審查記下的唯一 should-fix：in-range 但 Not Valid 的提示在硬體上仍會重啟端點，crosvm 這裡
  沒跟上，刻意留成下一支槓桿並用測試釘住）。同一個 commit 把 `f96fd65` 新加的
  `endpoint at index N is not running` 從 error! 降成 debug!（Linux 合法地會去停一個已經停掉的端點，
  Context State Error 才是給 guest 看的答案）。host 單元測試 **80 個全過**（`f96fd65` 的 77 ＋ 3）。
- **2026-09-06 驗收（run6，5568，crosvm `d849baf` md5 `65efdadc…`，證據在 scratchpad `m6b/uas/run6`）：
  4 次冷開機 ×（冷接上 ＋ 2 次熱插拔）＝ 12 次 attach，11 次乾淨、1 次仍被晾住。** duplicate-Stopped **0**、
  Stop Endpoint 到 Set TR Dequeue 的間隔 **0–1 ms**、crosvm ERROR **0**、每個 watch pattern 都 0、
  raw 未緩衝讀 **294.8–318.1 MB/s**、`disk.sys` DeviceStart **5–12 ms**（cold1 第一次的 1984 ms 與那條
  1977 ms 的 DCI-7 strand 是磁碟自己起轉——那是被報的 stream 2 的 URB 走一般的 cancel → 重下 → status 0x0，
  不是 restart-all 在重跑一顆 silent TD）。唯一的失敗是 cold2 的**第 3 次 attach**（第二次熱插拔）：一次
  Stop Endpoint 同時取消了**兩條** stream ring 的 TD，被報的 stream 2 URB 1 ms 內以 `0xC0000120` 收掉，
  silent 的 stream 3 仍舊 **16114 ms** 什麼都收不到（Kernel-PnP 902 WatchdogTriggered 1 次、
  `disk.sys` DeviceStart 16634 ms），那 16 秒裡 crosvm 的 log 只有一行「backend attached to port 9」。
  但這一輪比 run5 多出一個決定性的證據：**16 秒後那次重試的 Stop Endpoint completion code=1**，而
  `d849baf` 會對不是 Running 的端點回 Context State Error——端點當時是 Running，而唯一會寫 Running 的是
  `ring_doorbell`，且它是在 `get_trc` 拿到活的 ring 之後才寫，所以 **doorbell 確實到了、restart-all 也
  確實跑過**。修法六的假說成立、也不是這一次卡住的原因。12 次 attach 裡真正踩到「兩條 ring 都留著被取消的
  TD」的只有這一次（cold3 那次看起來像，但 stream 3 的 reap 帶回真實成功與資料、被正常完成掉，等於一條）。
- **修法七（`2a8e371`，分析 `plans/crosvm-xhci-designs/ANALYSIS-STREAM-RESTART-2.md`、設計
  `plans/crosvm-xhci-designs/DESIGN-STOPPED-DELIVERED.md`）：整顆 TD 都已經搬完的「被取消」是完成，
  不是停止。** 把 run6 那一次拉到微秒重建之後，剩下的不是重啟漏掉，而是一個**資料遺失的競態**：stop 的
  `USBDEVFS_DISCARDURB` 正好打在裝置把那個 tag 的 **256 B IU 整個送完、completion 還沒交回來**的瞬間，
  kernel 於是把 URB 以 -ENOENT（Cancelled）連同「已經搬完的全長」一起 reap 回來。crosvm 把它當成停止：
  默默倒回那條 ring、不發事件；Windows 手上拿到的是**另一條** stream 的 Stopped，就繼續掛著這顆 URB、
  把 TD 重新武裝；重啟後的 ring 照著再執行一次，換來一顆向裝置要「早就送出去、而且永遠不會再送一次」的
  資料的新 URB——於是整整 16 秒沒有東西動，直到 UASPStor 的 SRB 逾時送出 TASK MANAGEMENT IU 把那個 tag
  打掉（tag 狀態一重置，同一顆 256 B 傳輸微秒內就完成，裝置從頭到尾都是好的）。真實硬體不會有這一段：
  Stop Endpoint 是用鏈路層流控把傳輸凍住、restart 是**接續**，兩顆 URB 之間掉不了資料——crosvm 的
  「cancel URB ＋ 倒回 ＋ 從頭重跑」才是結構上的分歧。修法：reap 回來的 Cancelled 只要搬動的位元組數等於
  整顆 TD 的資料長度，就照它在線上真正發生的樣子當成完成——走一般的 IOC/ISP ＋ Event Data 事件（資料早就
  被 backend 的 Cancelled 分支抄進 guest buffer），不 `record_stopped`、不倒回、不消耗那份 Stopped 認領，
  ring 直接 park 在 TD 後面，那個 Stopped 留給真的還停在 TD 中間的 ring。順帶把一個潛在危害關掉：整顆送完的
  **OUT** TD 以前會被倒回、把資料再送給裝置一次。審查回合改了一件事：完成這條路的 transfer event 要排在
  **叫醒 ring 之前**送出——ring 一被叫醒就 park、就會放掉 Stop Endpoint 的 Command Completion，而 4.6.9
  要求這些事件排在那個完成**之前**，原本 signal-then-events 的順序會留一個 Success 落到命令完成後面的窗；
  事件迴圈抽成 `send_transfer_events`，送失敗時照樣 signal（否則 stop 會吊住）。另外加三條 debug! 給下一輪
  判讀用：doorbell 重啟了幾條 stream ring、每顆被取消的 TD 搬了多少／全長多少、每次送出 TD。host 單元測試
  **83 個全過**（`d849baf` 的 80 ＋ 3）。明文留下的殘留：**部分送達**（0 < bytes < TD 長度）仍舊倒回重執行，
  重執行的 TD 會把裝置那顆 IU 的**剩下半截**收進一顆全長的新 URB——資料錯位，但至少有完成、不會晾住；
  要真正治好得改成 resume-not-re-execute（讓 backend URB 活過 stop、重啟時認領回來），那是架構級的改動，
  這次沒做。
- **2026-09-06 驗收（run7，5568，crosvm `2a8e371` md5 `b4e04f56…`，同一支 binary 打包並安裝的 APK md5
  `6727760f…`；閘門式驗收，證據在 scratchpad `m6b/uas/run7`）：Windows 12/12 全過、Linux 與 app 路徑
  無回歸；但要驗的那個競態一次都沒有再出現。**
  - Windows（pseudo-unprotected，手動 launcher，4 次冷開機 ×3 ＝ 12 次 attach，crosvm 開
    `--log-level info,devices::usb::xhci=debug`）：**12 次 attach 全部通過每一條閘門**——duplicate-Stopped
    **0**、Kernel-PnP 902 WatchdogTriggered **0**、`disk.sys` DeviceStart **14–21 ms**（只有 cold1 第一次是
    1996 ms 的磁碟起轉）、slot 1 DCI-7 最長 strand **18–22 ms**（同樣只有那次的 1981 ms 例外，那顆 URB 是在
    stop 的取消完成之後 6 ms 才送出、最後以 status 0x0 收掉）、16 B 的 task-management IU **0** 顆、
    Stop Endpoint 到 Set TR Dequeue 最大 **1.0 ms**（門檻 200 ms）、crosvm ERROR **0**、watch pattern 全 0。
    讀取 **234.7–248.3 MB/s**，比 run6 的 ~300 MB/s 低約 20%——那是 `xhci=debug` 的代價（每次開機 41 MB log、
    54510 行 submitting TD ＋ 35961 行 doorbell），不是 `2a8e371`。
  - **但要驗的那條路從來沒有被走到**：四次開機一共只有 12 行 `cancelled TD`，每一行都是
    `0/192 bytes moved, stopped`（11 次在 stream 2、1 次在 stream 3），`completing` **0** 行、
    「兩條 ring 都留著被取消的 TD」的 stop 也是 **0** 次。所以 run7 證明的是 `2a8e371` **沒有回歸、
    新加的三條 debug! 正確而且便宜**，不是它治好了那 16 秒。獨立稽核員把原始證據整套重跑（自己重新配對四份
    ETW 的 UCX 26/27、重 grep 四份 41 MB 的 log）逐條 CONFIRMED，只糾正報告的一個數字（stop 到 cancelled-TD
    的延遲是 2–6 ms 不是 13–15 ms，結論不變），並補一句觀察：12 次取消抓到的全是 192 B 的 sense IU、
    不是 run6 那顆 256 B 的資料 IU，debug 的時間擾動很可能正好把那個窗壓掉了。
  - Linux（protected-without-firmware）：UAS dd **329.3／318.0 MB/s**（另外四次 308.7–317.4）、兩條併發 dd
    **190.7／190.1 MB/s**（`inflight` 取樣 0 4 4 3 0 0）、攝影機 3×60 幀 **15.00／15.00／15.01 fps**、
    `not part of TD` **0**、攝影機 mic `arecord` 64044 B、`speaker-test` rc=0（xrun 0）；crosvm log 與 run6
    同一形狀（WARN 14、ERROR 3 都是開機時的 `device slot is already enabled`），run6 那 4 條 uvcvideo
    `Failed to resubmit video URB` 這輪 **0** 條。
  - App 路徑（APK `6727760f…`，app 解出的 crosvm md5 就是 `b4e04f56…`，versionCode 2530）：AF（Ubuntu，
    裝置層規則）與 AW（Windows，只掛攝影機）共 15 個情境**全過**——`running` 之後 **9.28／9.50 秒**自動接上
    兩顆，攝影機 14.98–15.01 fps、`not part of TD` 0、mic 64044 B（32000 取樣裡 28633 非零）、
    `speaker-test` rc=0；Windows 那邊 **6.29 秒**只接走攝影機（AB13X 與 UNITEK 一路留在 host），PnP 三個
    VID_32E6 節點全 OK prob=0，console session 拍照 61304 B（1920×1080 JPEG）／錄影 137711 B（MP4），
    `vm_stop` 後 0.30 秒釋放。run5 記在這裡的兩條 `endpoint at index 0 is not running` ERROR 這輪沒有再出現
    （修法六把它降成 debug! 了）。三段 watchdog `HOST_REBOOT` 全 **0**，收尾乾淨。
- 稽核員另外記下一條沒有人解釋過的東西：**每一份 Windows trace（含全乾淨的 cold2 與 app 那一輪）都有一個永遠
  在跑的 ~33 秒 bulk URB 週期落在 DCI 1 上、每次以 `0xC0000120` 收尾**（每份冷 trace 三段 33.0–33.6 秒），收
  trace 的時候還帶著 `URBs never completed: 1`。過的與不過的 run 都一樣，所以對這個停滯沒有診斷價值（看起來
  像 detach 時被取消的 long poll），但沒有做過特徵化，也沒有跟 run4 對過基準。

**狀態總結（2026-09-06）：** isochronous 開工以來 `wip/usb` 上的 crosvm 是一條 12 個 commit 的鏈——
`11c5462`（event ring 還沒建起來時的 port change 不是失敗）、`b6c9027`／`baf456e`／`ce5a1d2`（Windows UASP
的 stream context 三修）、`391518c`（HCRST 重置 command ring／CRCR／interrupter）、`dc1e0bf`／`9293b36`／
`13242f9`／`e5eece2`／`f96fd65`／`d849baf`／`2a8e371`（Stop Endpoint 的七連修）——到 run7 為止，Windows
pseudo-unprotected、Linux protected-without-firmware 與 app daemon 三條路徑都在 5568 上實機驗過。
已知還沒解的六項：(1) **部分送達的取消**（0 < bytes < TD 長度）仍舊倒回重執行，資料會錯位，要
resume-not-re-execute 才是真正的解；(2) **MFINDEX Wrap Event**（USBCMD.EWE）沒做，等哪天 Windows 真的開
EWE 再補；(3) 開機時 firmware → kernel 交接處固定 2–3 條 `device slot is already enabled` ERROR，
判定無害但沒有追到底；(4) **bulk 仍是單佇列深度 1**，qd1 吞吐量被每筆請求的來回延遲綁住（§9.3）；
(5) 每份 Windows trace 都有的那個 **~33 秒 DCI-1 bulk URB 週期**，過的與不過的 run 都一樣，沒有特徵化過；
(6) 5568 的 **Type-C OTG 掉線**（§4 的 rig 註記），與 crosvm 無關，但會整棵 USB 樹一起消失、打斷驗收。

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
- 未做：**stream context 的 SCT=0 容忍**——`create_stream_trcs()` 現在要求主 Stream Context Array 的每一格（已修：crosvm `b6c9027`/`baf456e`/`ce5a1d2`，見 §9.1）
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
| Windows pseudo-unprotected（`f8029b85` 重測） | 274.8 / 322.5 / 332.7 MB/s（raw 未緩衝讀） | 未測 | 未測 | 2530 IOPS（非 fio） | 未測 | 未量 |
| Linux protected（`f8029b85` 重測，同一種 launcher） | 326 / 344 MB/s | 253 MB/s | 429 MB/s | 1458 IOPS | 6728 IOPS | 未量 |
| Windows pseudo-unprotected（`b55fcee2`＝`391518c` 重測） | 347.1 / 361.2 MB/s（raw 未緩衝讀）；三次 HCRST 之後 294.0 / 301.3、304.6 / 302.5、300.7 MB/s | 未測 | 未測 | 未測 | 未測 | 未量 |
| Linux protected（`b55fcee2`＝`391518c` 重測，同一種 launcher） | 315 / 321 MB/s | 240.0 MB/s | 431.6 MB/s | 1325 IOPS | 8398 IOPS | 未量 |

本輪（`11c5462`）Windows 整列量不到：磁碟從頭到尾沒列舉出來（`Get-Disk` 只看得到 VirtIO 系統碟，
沒有任何 PhysicalDrive），因為 crosvm 的 Configure Endpoint 被 `bad stream context type: 0` 打回、
xHCI 的事件處理器當場被拆掉，一個測項都沒跑到。表上 Windows 那列的數字是 2026-09-05／06 深夜用修好的
binary（`f8029b85` ＝ `ce5a1d2`）重量的，量法跟 Linux 不同：raw 未緩衝 `FileStream` 讀
`\\.\PhysicalDrive1`（磁碟全程 offline / read-only），三趟 2000×1 MiB 分別 274.8 / 322.5 / 332.7 MB/s，
4 KiB 隨機是自寫的 2000 次讀迴圈（2530 IOPS），Windows 端**沒有跑 fio**，所以 qd8/qd32 兩欄空著。
同一輪的 Linux protected 重測列在下一行（詳見 §9.1 的 streams 條目）。

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
- 重測那一列的兩處對不上，都還沒解釋：dd 從 234 升到 326 / 344 MB/s、fio qd1 從 233.9 升到 253 MB/s——
  stream 的修法對 Linux `uas` 不該有這種效果（它本來就每格都填 Linear、走的是同一條路），兩邊都是單次
  取樣，先當變異度看。
- **rand4k qd32 那個 −26% 是取樣變異，不是回歸（2026-09-06 凌晨 `b55fcee2` 重測結案）**：同樣的
  Linux protected ＋ 手動 launcher，qd32 回到 **8398 IOPS**，離 9099 的基準只差 8%（比 `f8029b85` 那輪的
  6728 高 25%）；同一輪 qd8 的 **431.6 MB/s** 還是三輪裡最高的。反方向的 seq qd1（240.0，−5%）與 rand4k qd1
  （1325 IOPS，−9%）都是單一在途 IO 的延遲數字，同屬變異；buffered dd 315 / 321 MB/s 也仍在 234 MB/s 基準之上。
  唯一的量法差異：這輪 fio 每個 job 跑 20 秒（前兩輪 15 秒），所以 qd1 的比較本來就弱一點。

**打死整台 xHCI 的那個 `bad stream context type: 0`（本輪 Windows 量不到東西的原因）：診斷、三個 commit
的修法、以及修好之後的實機驗收，全部記在 §9.1。**
