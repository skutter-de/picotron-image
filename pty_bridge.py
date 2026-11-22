#!/usr/bin/env python3
"""PTY bridge: TCP port 2323 → bash shell with PTY"""
import pty, os, socket, select, signal, sys, re, fcntl, termios, struct, base64, subprocess

PORT = 2323
COLS = 80
ROWS = 22

RESIZE_RE = re.compile(rb'\x1b\[8;(\d+);(\d+)t')
OSC52_RE  = re.compile(rb'\x1b\]52;([cp][^\x07\x1b]*?)(?:\x07|\x1b\\)')

def apply_resize(master_fd, child_pid, rows, cols):
    try:
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', rows, cols, 0, 0))
        os.kill(child_pid, signal.SIGWINCH)
    except Exception:
        pass

def handle_osc52(payload, master_fd):
    # Anwendungen (z.B. Claude Code) schreiben via OSC 52 ins Clipboard
    if payload.startswith(b'c;'):
        try:
            text = base64.b64decode(payload[2:])
            subprocess.run(['wl-copy'], input=text, check=False)
        except Exception:
            pass

def strip_client_seqs(data, master_fd, child_pid):
    def on_resize(m):
        apply_resize(master_fd, child_pid, int(m.group(1)), int(m.group(2)))
        return b''
    def on_osc52(m):
        handle_osc52(m.group(1), master_fd)
        return b''
    data = RESIZE_RE.sub(on_resize, data)
    data = OSC52_RE.sub(on_osc52, data)
    return data

def handle(conn):
    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ['COLUMNS'] = str(COLS)
        os.environ['LINES'] = str(ROWS)
        drive = os.path.realpath(os.path.expanduser('~/.lexaloffle/Picotron/drive'))
        if os.path.isdir(drive):
            os.chdir(drive)
        os.environ['_PTRON'] = drive
        rcfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'picotron_bashrc')
        os.execvp('/bin/bash', ['/bin/bash', '--rcfile', rcfile])
    try:
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', ROWS, COLS, 0, 0))
        while True:
            r, _, _ = select.select([conn, master_fd], [], [], 0.001)
            if conn in r:
                data = conn.recv(4096)
                if not data:
                    break
                data = strip_client_seqs(data, master_fd, pid)
                if data:
                    os.write(master_fd, data)
            if master_fd in r:
                try:
                    data = os.read(master_fd, 4096)
                    if not data:
                        break
                    conn.sendall(data)
                except OSError:
                    break
    finally:
        conn.close()
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        except Exception:
            pass

def main():
    import threading
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', PORT))
    srv.listen(5)
    print(f"PTY bridge listening on port {PORT}", flush=True)
    while True:
        conn, addr = srv.accept()
        print(f"Connected: {addr}", flush=True)
        t = threading.Thread(target=handle, args=(conn,), daemon=True)
        t.start()

if __name__ == '__main__':
    main()
