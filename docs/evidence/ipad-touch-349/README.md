# Direct-touch iPad controls — issue #349

Validated July 30, 2026 in the iPad Pro 11-inch (M5), iPadOS 26.5
Simulator.

- The world surface is one full-screen touch target behind the HUD.
- A quick tap queues use/interact/place at the crosshair.
- A 300 ms hold starts mine/attack and release or cancellation stops it.
- Moving 14 points from the initial touch cancels tap/hold recognition and
  leaves the gesture as camera look.
- Movement remains a separate tracked touch in the left joystick, so a real
  iPad can move and look/act simultaneously.
- Dedicated MINE and USE buttons are removed.
- Large joystick, jump, descend, and taller hotbar controls are now the
  default.
- Compact, Large, and XL thumb-control presets are available from the pause
  card and persist in `UserDefaults`.

`direct-touch-large.png` shows the new default HUD.
`touch-size-menu.png` shows the saved size control and revised instructions.

The issue remains open until physical-device multitouch is confirmed.
