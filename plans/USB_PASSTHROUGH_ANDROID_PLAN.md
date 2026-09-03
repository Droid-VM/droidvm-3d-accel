# USB 透傳：Android 端接線計劃（2026-09-04）

前提（USB_PASSTHROUGH_SURVEY.md 的結論）：Linux guest 走 protected + restricted-dma-pool，
Windows guest 走 pseudo-unprotected；兩者 host 端機制相同，差別只在 crosvm 的 gate。本文只講
Android 這一側：硬體、kernel、誰擁有裝置、daemon 的管理模型、app 的事件與頁面、驗證。

## 0. 先回答：插隨身碟時 Android 跳的「要開啟 X 以控制 Y 嗎」是什麼

裝置在 Android 上有**兩層**所有權，實機（5568，hub `214b:7250` 底下一顆 Silicon-Power 隨身碟
`090c:1000` 和一張 Realtek `0bda:8153` 網卡）：

| 層 | 誰 | 實機狀態 |
|---|---|---|
| kernel | usbcore 列舉後，class driver 綁**介面** | `1-1.1:1.0 → usb-storage`（成了 `sdg`，vold 掛成 `public:8,97 mounted`）；`1-1.2:1.0 → r8152`（成了 `eth0`，host kernel 竟然有這個驅動） |
| framework | system_server 的 `UsbHostManager`（`libusbhost` 用 inotify 盯 `/dev/bus/usb`）把裝置登記進 `UsbService`，對 manifest 裡有 `device_filter` 的 app 發 `ACTION_USB_DEVICE_ATTACHED`，有匹配就跳 `UsbConfirmActivity` | `dumpsys usb` 列出四個登記者：`com.android.mtp`、Google 相簿、`com.paragon.tcplugins_ntfs_ro`、`com.proxmini.proxmini`。隨身碟那個對話框八成是 Paragon NTFS 外掛 |

所以那個對話框**不是 kernel 驅動接管**，是 framework 在問要不要把 usbfs fd 交給某個 app；kernel
的 usb-storage 早在對話框之前就已經把它掛起來了。app 拿到 fd 後若 `claimInterface(force=true)`
才會踢掉 kernel driver。

我們**不走 framework 這層**：daemon 是 root（實測 `u:r:magisk:s0` 直接 `dd` 讀
`/dev/bus/usb/001/004` 拿到 device descriptor，SELinux 放行），把節點交給 crosvm；crosvm 對 active
config 的每個介面做 `USBDEVFS_DISCONNECT_CLAIM`（`usb_util/src/device.rs:366-381`，driver 名全零 =
不管誰綁著都踢掉再 claim）。這正是你要的「guest 驅動接管整顆硬體」：
- host 有驅動（usb-storage / r8152 / hid）：被踢掉，vold 看到 `sdg` 消失、`eth0` 消失。
- host 沒驅動：介面本來就沒人綁，claim 直接成功。**行為完全相同**，不依賴 host 有沒有驅動。
- 代價與善後：踢掉後 kernel **不會**自動重綁；crosvm 放掉 fd（detach 或 VM 結束）後裝置介面留在
  unbound 狀態，直到重插。daemon 要主動 `echo 1-1.1:1.0 > /sys/bus/usb/drivers_probe` 還給 Android
  （root 可寫）。framework 那層完全不用管：它只看節點存不存在，對話框照跳（可忽略），其他 app 若已
  拿著 fd 也會被 claim 踢掉。

## 1. 硬體與 kernel：不用改任何東西

- 三台都有 `android.hardware.usb.host`，host kernel `USB_DWC3_DUAL_ROLE` + `USB_ROLE_SWITCH` +
  `USB_XHCI_HCD`；接 OTG hub 自動切 host（5568 實測 `usb_role = host`；5566/5567 空著 = `none`）。
  adb 走網路，USB-C 是空的。
- usbfs 節點：`/dev/bus/usb/BBB/DDD`，ueventd `0660 root usb`、framework 接手後 chown
  `system:system`、label `usb_device`；root 直讀 OK。不需要 usbfs 以外的任何 host 介面。
- 不需要新的 host kernel 模組：記憶體全走 crosvm 既有的 swiotlb 區（SHARE），gunyah_host_mod 無事。
- 速度：這顆 hub 是 USB 2.0（480 Mbps），兩個子裝置都是 480。USB 3 裝置要 USB 3 hub/線。crosvm 的
  xHCI 同時有 USB2 與 USB3 port 段（`usb_hub.rs:196-206`，`connect_backend` 按裝置速度挑段），
  所以 attach 時不用管，但 port 數有限（`MAX_PORTS`，控制指令上限 16）。
- 供電：手機當 host 要餵 VBUS；長時間掛硬碟/網卡建議 PD 供電 hub，否則耗電。
- autosuspend：usbfs 開著會 `usb_autoresume_device`，crosvm 持有 fd 期間裝置不會被 host 休眠。
- 一顆 dwc3 服務整台手機，guest 拿走的是**裝置**不是控制器；hub 自己（`1-1`）留給 host，不要
  attach hub。

## 2. Android 端管理模型：daemon 是唯一權威

app 是 UI，所有狀態住在 root daemon。理由：daemon 已經是 root、常駐、fork crosvm、握有每個 VM 的
控制 socket（`CrosvmBackendInstance.java:147`），而且 `UsbManager` 那條路要跟 framework 要權限、
app 不在前景就收不到。

### 2.1 清冊（host 裝置）
直接掃 `/sys/bus/usb/devices/`（不經 `UsbManager`）。每顆裝置：`sysfs 名（=port path，如 1-1.2）`、
`busnum/devnum → /dev/bus/usb/BBB/DDD`、`idVendor/idProduct`、`manufacturer/product/serial`、
`speed`、`bDeviceClass`、每個介面的 `bInterfaceClass/SubClass` 與目前綁的 `driver`（readlink）。
跳過 root hub（`usb1/usb2`）與 hub（class 09）。這份清冊就是 UI 的資料來源，也是 host 端
「有沒有被 Android 用著」的顯示依據（driver 欄）。

### 2.2 熱插拔
daemon 用 `FileObserver`（inotify，`app_process` 裡可用）盯 `/dev/bus/usb/*/`：這就是 system_server
自己的做法。
- `CREATE`：讀 sysfs 建條目（節點出現時 sysfs 已齊）→ 跑 §2.4 的自動規則 → 廣播 `usb_host_changed`。
- `DELETE`：若該裝置 attach 在某 VM → 對該 VM 發 `crosvm usb detach <port>`（**必要**：crosvm 只在
  下一筆 transfer 撞 `ENODEV` 時才自己 `port.detach()`，`xhci_transfer.rs:339-343`；閒置的隨身碟被拔了
  guest 不會知道）→ 清表 → 廣播。
- 匯流排目錄本身（`/dev/bus/usb/001`）出現/消失（role 切換）也要盯，重掛 observer。

### 2.3 佔用與衝突
- 一顆裝置同時只能在一個 VM。daemon 維護 `device(sysfs 名) → (vm_id, crosvm port)`，attach 前查表；
  `crosvm usb list <sock>` 用來在 daemon 重啟後重建表（VM 可能還活著）。
- Android 端綁著驅動**不算**佔用（會被踢）；但 UI 要把「host 正在用（usb-storage 已掛載 / eth0）」標出來，
  讓使用者知道 attach 會把它從 Android 拔走。mass storage 可選擇先 `sm unmount public:X,Y` 再 attach，
  避免 vold 報「意外移除」。
- 拒絕 attach 的情況：hub、root hub、VM 不在 RUNNING、VM 是 protected + Windows（沒有 xHCI，
  survey R2）、port 用完。

### 2.4 規則（存在 VM config）
```json
"usb_devices": [
  { "vid": "090c", "pid": "1000", "serial": "1400973503822014", "auto": true },
  { "port_path": "1-1.2", "auto": true },
  { "vid": "0bda", "pid": "8153", "auto": false }
]
```
- `vid/pid`（必）+ `serial`（選，區分同型號）；`port_path`（選，= hub 的哪個孔，換裝置也接）；
  `auto`：true = 插入即接、VM 開機掃一次；false = 只在 UI 手動接時當作「已知裝置」。
- class 規則（例如「所有 mass storage」）第二階段再加。
- 多個 RUNNING VM 同時命中：先到先得（VM 開機順序 / 規則建立順序），並廣播衝突事件給 UI。

### 2.5 事件時序
| 事件 | daemon 做什麼 |
|---|---|
| VM → RUNNING（`VMInstance.setState`，crosvm 控制 socket 就緒之後） | 遍歷清冊：未被佔用 且 匹配該 VM 的 `auto` 規則 → attach |
| 裝置插入 | 對每個 RUNNING VM 跑規則 → attach；無人命中則只更新清冊 |
| 使用者手動 attach / detach | 新 IPC（§2.6）→ attach/detach → 更新表 → 廣播 |
| 裝置拔除（attach 中） | `crosvm usb detach` → 清表 → 廣播 |
| VM → STOPPING / STOPPED / crosvm 死掉 | crosvm 退出自動放 fd；daemon 清掉該 VM 的表 → 對每個介面 `drivers_probe` 還給 Android → 廣播 |
| daemon 啟動 | 掃清冊；對每個活著的 VM `crosvm usb list` 重建表 |

### 2.6 IPC（daemon ↔ app，沿用 `daemon/ipc/vm/*Handler` 的樣子）
- `usb_host_list` → 清冊 + 每顆的佔用者。
- `usb_attach {vm_id, device}` / `usb_detach {vm_id, device|port}`。
- `usb_vm_list {vm_id}` → 該 VM 目前 attach 的裝置與 port。
- 廣播事件（`Server.broadcastEvent`）：`usb_host_changed`、`usb_vm_changed`、`usb_conflict`。

## 3. crosvm 端接線（daemon 怎麼叫它）

- gate：`src/crosvm/cmdline.rs:3859-3864` 改成「memory 隔離且沒有 swiotlb 才關 usb」，讓
  `ProtectedWithoutFirmware`（有 pool）與 `ProtectedPseudoUnprotected`（RAM 全 SHARE）都放行。
- attach：daemon 用 `NativeProcess`（同 `CrosvmBackendInstance.java:185` 的 env / `LD_LIBRARY_PATH`）跑
  `crosvm usb attach 0:0:0:0 /dev/bus/usb/BBB/DDD <sock>`；CLI 自己開檔、經控制 socket 把 fd 傳給
  VMM（`vm_control/src/client.rs:125-139`），輸出含分配到的 port，daemon 解析後記表。
  detach：`crosvm usb detach <port> <sock>`；list：`crosvm usb list <sock>`（16 個 port 的 vid:pid）。
  第二階段可改成直接在既有的 SEQPACKET `LocalSocket`（`runControlCommand`，`:1589-1624`）上寫
  `UsbCommand` JSON + `setFileDescriptorsForSend`，省一次 exec。
- crosvm 端小改（可選，非阻塞）：attach 回覆帶 vid:pid；host 端拔除時主動發事件（現在沒有，
  用 §2.2 的 inotify 補）。

## 4. app 端

1. **USB 管理頁（全域，設定 → USB）**：清冊表格——名稱、`vid:pid`、serial、速度、介面 class、
   host 狀態（Android 驅動/已掛載/空閒）、目前在哪個 VM；每列「接到…」選 RUNNING 的 VM、「拔除」。
   資料來自 `usb_host_list`，靠事件刷新。
2. **VM 編輯頁 → 新增 USB 分頁**：規則清單（§2.4），「從目前插著的裝置加入」一鍵填 vid/pid/serial/
   port_path；每條有 `auto` 開關。protected + Windows 時整頁灰掉並說明只支援 pseudo-unprotected。
   Basic 分頁既有的 `usb` 開關（xHCI 有無）保留。
3. **VM 資訊頁**：目前 attach 的裝置 + 拔除按鈕；衝突事件用 snackbar。
4. **不要**在 manifest 加 `device_filter` / `ACTION_USB_DEVICE_ATTACHED` intent-filter，否則每次插裝置
   Android 都會問要不要開 DroidVM。既有的 `uses-feature android.hardware.usb.host required=false` 留著。
   `UsbHidInput.java` 那套 `UsbManager` 流程只給外接顯示的 HID 用，與透傳無關，不要混用。
5. 既有 `OsKernelWithoutRestrictPoolHandler` 會抓 `host access to lent memory`；若 protected Windows 誤開
   xHCI 會由它報，訊息裡加一句 USB 的解釋即可。

## 5. 驗證（用 5568 現成的 hub + 隨身碟 + Realtek 網卡）

階段 A —— crosvm gate 拿掉，手動 CLI，不動 daemon/app：
1. Linux protected VM 開機：guest `lspci` 有 `1b73:1400` xHCI、`dmesg | grep xhci` 初始化無錯、host log
   `host access to lent memory` 0 筆（這是 survey R1，最先驗）。
2. `crosvm usb attach 0:0:0:0 /dev/bus/usb/001/004 <sock>` → host：`sdg` 消失、vold 報移除；guest：`lsusb`
   看到 `090c:1000`、`dmesg` 出現 usb-storage、`dd` 讀寫；`crosvm usb detach` → guest 裝置消失；host
   `drivers_probe` 後 `sdg` 回來、vold 重掛。
3. 網卡 `0bda:8153`：guest `r8152` 綁上、拿到 IP；host `eth0` 消失/回來。
4. 拔線測試：attach 中把隨身碟拔掉 → 手動 `usb detach` 前 guest 是否察覺（預期：閒置時不會，證明 §2.2 的必要）。
5. Windows VM 改 pseudo-unprotected：裝置管理員出現 xHCI（inbox USBXHCI），attach 隨身碟 → 磁碟管理看得到；
   protected Windows（`usb: true`）開機 → 確認 daemon 端拒絕/或 xHCI 缺席，不能炸。

階段 B —— daemon：清冊、IPC、runtime attach/detach、inotify 拔除、VM 停止還原（`drivers_probe`）、
daemon 重啟重建表。用 CLI 對 IPC 打，不靠 UI。

階段 C —— app 三個頁面 + 事件刷新；階段 D —— 自動規則（開機掃一次、插入即接、衝突）。

回歸：unprotected VM 照常；VM `usb=false` 完全沒 xHCI；兩個 VM 搶同一顆裝置只能一個成功。

## 6. 里程碑
- M1 crosvm gate + 階段 A（實機證明機制通）。
- M2 daemon（§2）+ IPC（§2.6）+ 階段 B。
- M3 app 頁面（§4）+ 階段 C。
- M4 自動規則 + 衝突 + 階段 D。
- M5 Windows pseudo-unprotected 驗收；protected Windows 的拒絕路徑。
