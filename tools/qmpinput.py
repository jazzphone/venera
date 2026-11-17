#!/usr/bin/env python3
# qmpinput (stage 5c): mouse gestures into a VM's virtual tablet over QMP, for measuring drags and scrolls without
# anyone at the screen. Runs on the Proxmox host; one short QMP connection per gesture.
#   qmpinput.py VMID drag X0 Y0 SECONDS [RADIUS]     press at (X0, Y0), move in circles, release
#   qmpinput.py VMID scroll X Y SECONDS [DIRECTION [DZ]]  wheel ticks every 16 ms over (X, Y) (down or up, DZ each)
#   qmpinput.py VMID click X Y
#   qmpinput.py VMID rclick X Y                         a right click (a context menu)
#   qmpinput.py VMID line X0 Y0 X1 Y1 SECONDS          press at (X0, Y0), move straight to (X1, Y1), release
# Coordinates are screen points of a 1280x800 display, top-left origin.
import json, math, socket, sys, time

W, H = 1280, 800

def connect(vmid):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(f"/var/run/qemu-server/{vmid}.qmp")
    f = s.makefile("rw")
    f.readline()  # greeting
    send(f, {"execute": "qmp_capabilities"})
    return s, f

def send(f, cmd):
    f.write(json.dumps(cmd) + "\n")
    f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            return r

def events(f, evs):
    return send(f, {"execute": "input-send-event", "arguments": {"events": evs}})

def move(f, x, y):
    return events(f, [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / W)}},
                      {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / H)}}])

def button(f, b, down):
    return events(f, [{"type": "btn", "data": {"down": down, "button": b}}])

def main():
    vmid, what = sys.argv[1], sys.argv[2]
    s, f = connect(vmid)
    try:
        if what == "click":
            x, y = float(sys.argv[3]), float(sys.argv[4])
            move(f, x, y); time.sleep(0.05)
            button(f, "left", True); time.sleep(0.05); button(f, "left", False)
        elif what == "rclick":
            x, y = float(sys.argv[3]), float(sys.argv[4])
            move(f, x, y); time.sleep(0.15)
            button(f, "right", True); time.sleep(0.08); button(f, "right", False)
        elif what == "drag":
            x0, y0, secs = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
            r = float(sys.argv[6]) if len(sys.argv) > 6 else 120
            move(f, x0, y0); time.sleep(0.2)
            button(f, "left", True); time.sleep(0.1)
            t0 = time.time(); n = 0
            while time.time() - t0 < secs:
                a = (time.time() - t0) * 2 * math.pi / 2.0  # one circle every 2 s
                move(f, x0 + r * math.sin(a), y0 + r * (1 - math.cos(a)) * 0.5)
                n += 1
                time.sleep(max(0, t0 + n / 60.0 - time.time()))
            move(f, x0, y0); time.sleep(0.05)
            button(f, "left", False)
            print(f"drag: {n} moves in {time.time() - t0:.1f} s")
        elif what == "line":
            x0, y0, x1, y1, secs = (float(v) for v in sys.argv[3:8])
            move(f, x0, y0); time.sleep(0.2)
            button(f, "left", True); time.sleep(0.15)
            steps = max(2, int(secs * 60))
            for i in range(1, steps + 1):
                move(f, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
                time.sleep(secs / steps)
            time.sleep(0.1)
            button(f, "left", False)
            print(f"line: {steps} moves")
        elif what == "scroll":
            x, y, secs = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
            d = sys.argv[6] if len(sys.argv) > 6 else "down"
            move(f, x, y); time.sleep(0.1)
            t0 = time.time(); n = 0
            dz = int(sys.argv[7]) if len(sys.argv) > 7 else 4
            while time.time() - t0 < secs:
                # QMP's wheel buttons don't reach macOS through the tablet; the monitor's relative wheel does
                send(f, {"execute": "human-monitor-command",
                         "arguments": {"command-line": f"mouse_move 0 0 {dz if d == 'down' else -dz}"}})
                n += 1
                time.sleep(max(0, t0 + n * 0.016 - time.time()))
            print(f"scroll: {n} ticks in {time.time() - t0:.1f} s")
    finally:
        s.close()

main()
