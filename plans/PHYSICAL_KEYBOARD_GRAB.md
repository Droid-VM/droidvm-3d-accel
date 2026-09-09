# 實體鍵盤直通 VM：evdev 獨佔（2026-09-09）

> 狀態（2026-09-09）：daemon／crosvm／UI 三側都已實作，5567（OnePlus OPD2404，Android 16）上
> 的 EVIOCGRAB PoC 已驗過（見 §1.3）。逃生鍵的**機制**做好了但**綁定留空**，之後補可讓使用者
> 自訂的 GUI。

目標（使用者的原話）：「想讓使用者能在 VM 操作介面裡面，物理鍵盤（attached to Android）各種
快捷鍵能直接傳給 VM」。這裡的「物理鍵盤」是 Android 角度的物理鍵盤 —— 廠商鍵盤保護套、藍牙
鍵盤、沒有被 USB 透傳搶走的 USB 鍵盤，一律算數。

這件事和 USB 透傳（USB_PASSTHROUGH_ANDROID_PLAN.md）沒有關係：5567 上的鍵盤走藍牙，
`/sys/bus/usb/devices` 是空的。兩者唯一的交集在 §5.4。

## 1. 為什麼現在的路徑到不了

### 1.1 第一層：Android 在 app 之前就把鍵吃掉

現況的鍵盤路徑是 `VMNativeDisplayActivity.dispatchKeyEvent()` → `KeyCodeMapper`（Android
keycode → evdev KEY_*）→ `InputForwarder` → daemon → crosvm `--input keyboard[path=...sock]`。
一般打字沒問題，但 Home、最近工作、Alt+Tab（Android 14+ 的系統切換器）、Meta/Super 系列快捷都在
`interceptKeyBeforeDispatching` 被 window manager 拿走，Activity 根本收不到；音量鍵是 app 自己
讓回給 Android 的（`VMNativeDisplayActivity.java` 的 `dispatchKeyEvent`）。這一層無論 app 怎麼寫
都拿不到 —— 它不是 app 的權限問題，是 dispatch 順序問題。

### 1.2 第二層：crosvm 的鍵盤能力表少了半個鍵盤

`devices/src/virtio/input/defaults.rs` 的 `default_keyboard_events()` 原本只宣告一份 en-us 子集，
裡面**沒有** `KEY_LEFTMETA`/`KEY_RIGHTMETA`（125/126，就是 Win／Super 鍵）、`KEY_102ND`、
F13–F24、日韓鍵、多媒體鍵。guest 的 input core 對能力表以外的 code 直接丟棄，Windows 的 VioInput
也只會照那張表生 HID report descriptor —— 所以 `KeyCodeMapper` 明明有把 META 對到 125 送出去，
Win 鍵在 guest 端仍然不存在。**這一層和 Android 攔不攔無關，是本來就壞的。**

修法：能力表改成宣告 `KEY_ESC(1)..KEY_MICMUTE(248)` 整段 —— Linux 給鍵盤的每一個 code，停在
`0x100` 的 `BTN_*`（滑鼠／手把按鍵，屬於指標裝置）之前。真實 USB 鍵盤本來就是這樣宣告整段能力，
host 送得出什麼是 host 的事。

### 1.3 PoC：grab 之下這些鍵拿得到，而且 Android 收不到

5567 實測（2026-09-09，工具 `kbdgrab.c`，`su -c` 執行，90 秒後自動 ungrab）：

| 項目 | 結果 |
|---|---|
| `EVIOCGRAB` on `/dev/input/event13`（Bluetooth Keyboard 04e8:7021）| OK（ksu root，無 SELinux 阻礙）|
| Win 鍵 | `code=125` 收到 4 次按放 |
| Alt+Tab | `code=56` + `code=15` 收到 |
| Win+D、字母 | 全數收到 |
| Android 反應 | 90 秒內 `dumpsys window` 取樣 39 次，焦點**全部**都還在 `VMNativeDisplayActivity`；沒有跳桌面、沒有切換器 |

## 2. 設計

一句話：**daemon（root，`u:r:ksu:s0`）EVIOCGRAB 主機上的實體鍵盤，把 raw evdev 直接寫進該
console 對應螢幕的 keyboard socket。**

daemon 本來就是 crosvm `--input` socket 的唯一 writer（`NativeDisplayInputBridge`），所以下游
什麼都不用改：guest 分不出這個鍵是實體鍵盤來的還是螢幕小鍵盤來的。

```
實體鍵盤 ──EVIOCGRAB──> KeyboardGrabManager ──8-byte virtio 記錄──> (vmId, screenId) 的 keyboard socket ──> crosvm ──> guest
                              ^
                              │ setKeyboardGrab(vmId, screen, grab, token)   [binder]
                        PhysicalKeyboardGrab（console 端只決定「何時」）
```

### 2.1 哪些節點算鍵盤

`HostKeyboard.scan()` 掃 `/dev/input/event*`，判準只有一條：EV_KEY 位元圖裡有
`q a z enter space`。**不看匯流排**，所以 pogo 保護套、藍牙鍵盤、USB 鍵盤一視同仁；手機自己的
音量鍵、電源鍵、觸控板、觸控螢幕因為沒有字母鍵而自然排除。節點路徑不是身分（藍牙鍵盤重連會換
`eventN`），身分是 name + vendor/product。

### 2.2 什麼時候 grab（這是整個設計的重點）

console 端（`PhysicalKeyboardGrab`）只判斷四件事，全部成立才要：

1. console 在前景（`onResume`/`onPause`）；
2. **鍵盤模式不是 `KeyboardMode.SYSTEM`** —— SYSTEM 是文字由系統 IME 產生的模式，而被 grab 的
   鍵盤 IME 是看不到的。切到 SYSTEM 就把鍵盤還給 Android，中文與一切組字輸入照舊走
   `dispatchKeyEvent`；NONE 和 LAPTOP 兩種模式才 grab；
3. 這個螢幕有開 input（`screenInputEnabled`）；
4. daemon 的 broker binder 連上了。

daemon 端（`KeyboardGrabManager`）再加兩個條件：功能沒被關掉、目標 VM 在 RUNNING。

**armed 與 held 是兩件事**：console 要了就進 armed，即使當下一把鍵盤都沒有、或 VM 還沒起來
（console 通常是先開介面才去 start VM）。VM 轉 RUNNING 時由 state hook 補抓，鍵盤插進來時由
uevent watcher 補抓。

### 2.3 路由：哪一把鍵盤、哪一個螢幕、哪一台 VM

grab 的目標是 `(vmId, screenId)`，送出時走 `vm.writeNativeInput(screenId, KEYBOARD, ...)`。
keyboard 這個 channel 在 `NativeDisplay.isPerScreen()` 裡是 per-screen，所以 simplefb 和
virtio-gpu 各有自己的 virtio 鍵盤，進哪個顯示介面就送進哪一把。跨 VM 同理。

交接的順序陷阱：Android 是**先 resume 進來的 Activity、再 pause 離開的**，所以離開的那個若無條件
release，就會把鍵盤從已經在前景的那個手上搶走。因此 console 的釋放走
`releaseFor(vmId, screenId)`，比對不中就不動手；而新 console 的 `request()` 遇到不同目標會先接管。

### 2.4 放開時要補 key-up

release 之前，對每一顆還按著的鍵補送 `value=0` + SYN。否則使用者按著 Ctrl 切走，guest 裡那顆
Ctrl 會一直按著，比 grab 和 console 都活得久。

### 2.5 自動重複（auto-repeat）丟掉

host 的 input core 會替按住的鍵產生 `value=2`，guest 的 input core 對 virtio 鍵盤也會做同一件事
（能力表有 EV_REP）。兩邊都做就會重複兩次，所以 `value=2` 不轉送。

### 2.6 熱插拔

armed 期間 daemon 開著 kernel uevent socket，看到 `SUBSYSTEM=input` 就 debounce 200 ms 後重掃，
把新出現的鍵盤補進 grab。藍牙鍵盤掉線時 reader thread 會讀到 hangup／ENODEV 自行退出並從清單移除，
但 console 保持 armed，重連（換一個 `eventN`）就自動接回去。

### 2.7 逃生鍵：機制做好，綁定留空

被 grab 的鍵盤在 Android 上什麼都按不動，所以逃生組合鍵必須由 daemon 自己攔（它才是持有者）。
機制在 `KeyboardGrabConfig.escapeChord`：一組 evdev KEY_* code，全部同時按住就放開，觸發的那一下
不轉送給 guest。**預設是空的**，因為「哪一組不會和 guest 搶」取決於 guest 是什麼，那是使用者的
決定，等有頁面可以說了再說。在那之前的出路本來就有兩條，而且都不需要鍵盤：離開顯示介面（觸控），
或把鍵盤模式切成 SYSTEM。

## 3. 介面

| 介面 | 形式 | 說明 |
|---|---|---|
| `setKeyboardGrab(vmId, screen, grab, token)` | binder（`INativeDisplayRootService`）| console 專用。`token` 是 console 自己的 binder，死了 daemon 就放開 |
| `kbd_status` | IPC | 設定、armed 的 console、held 的鍵盤、主機上所有鍵盤 |
| `kbd_config` | IPC | `enabled`、`escape_chord`（KEY_* code 陣列），寫回 `files/keyboard_grab.json` |
| `kbd_grab` | IPC | 無 console 的 grab／release，給 CLI 和測試用；沒有 token，所以 VM 離開 RUNNING 就整個放掉 |

## 4. 動到的檔案

crosvm（`wip/usb`）：
- `devices/src/virtio/input/defaults.rs` —— 鍵盤能力表改成整段（§1.2）。

app（`wip/usb`）：
- `cpp/unixhelper/unixhelper.c` + `lib/natives/UnixHelper.java` —— evdev 的 open／EVIOCGRAB／
  EVIOCGNAME／EVIOCGID／EVIOCGBIT；讀寫沿用既有的 `nativeRead`/`nativeWrite`/`nativePollIn2`。
- `daemon/input/HostKeyboard.java`、`KeyboardGrabManager.java`、`KeyboardGrabConfig.java`。
- `daemon/ipc/input/Keyboard{Status,Config,Grab}Handler.java`（`@AutoService` 自動註冊）。
- `daemon/server/ServerContext.java`（持有 manager）、`daemon/vm/VMInstance.java`（state hook，
  和 USB 的 hook 並排）、`daemon/display/NativeDisplayBinder.java`（實作 AIDL）。
- `ui/vm/display/base/PhysicalKeyboardGrab.java` + `VMNativeDisplayActivity` 的四個接點
  （建構、binder 連上／掉、鍵盤模式、resume/pause/destroy）。

## 5. 不做的部分與已知限制

### 5.1 VNC console 不 grab
VNC 匯出的螢幕，鍵盤是 crosvm 自己從 RFB event 餵的，daemon 這側根本沒有那個 keyboard socket
（`NativeDisplayInputBridge` 的註解說得很清楚）。所以 grab 只接 native display console。要支援
VNC 的話得把 grab 到的 evdev 轉成 X keysym 再從 app 送出去，是另一條路。

### 5.2 滑鼠／觸控板沒有跟著 grab
只有鍵盤被獨佔，保護套上的觸控板還是 Android 的。VNC console 那邊已經有
`requestPointerCapture()` 的先例，要做是同一個形狀，但不在這次範圍。

### 5.3 LED 沒有回寫
guest 端切 CapsLock 時，crosvm 會把 EV_LED 狀態寫回 socket，而 daemon 這側沒有人讀
（既有行為，不是這次造成的）。實體鍵盤的燈因此不會亮。真要做的話是同一件事的兩面：讀掉 socket
回傳的狀態，順手寫進實體鍵盤的 `EV_LED`。

### 5.4 和 USB 透傳的關係
被透傳到 guest 的 USB 鍵盤由 usbfs 佔住，主機端根本沒有 evdev 節點，所以掃不到也不會搶 —— 兩套
機制天然互斥。反過來，USB passthrough 的 `drivers_autoprobe=0` gate 期間插進來的鍵盤，要等規則
判定把它留給 host、`usbhid` 綁上去、evdev 節點出現，uevent 才會叫醒這裡的重掃。

### 5.5 逃生鍵未綁定
見 §2.7。

## 6. 驗證計畫（5567，Windows 11 ARM64 guest）

1. 裝上新 APK（含新 crosvm）後，開 VM 顯示介面，模式 NONE：`kbd_status` 應該顯示 armed 且
   held 至少一把（`/dev/input/event13`）。
2. Win 鍵 → Windows 開始功能表；Alt+Tab → Windows 的切換器；Win+D → 顯示桌面。同時
   `dumpsys window` 的焦點不動。
3. 切成 SYSTEM 模式 → `kbd_status` 的 held 應該歸零，實體鍵盤回到 Android（IME 可以打中文）。
   切回 NONE/LAPTOP → 重新 grab。
4. 按著 Ctrl 離開顯示介面 → guest 端不應該卡住 Ctrl。
5. 藍牙鍵盤關閉再開啟 → 幾秒內自動重新 grab（`kbd_status` 的 held 回來）。
6. `vm_stop` → held 歸零、鍵盤回到 Android；VM 再起來且 console 還在前景 → 自動接回。
