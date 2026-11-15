import os
import pty
import re
import select
import sys

ansi_escape = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
prog_re = re.compile(r"\[(\d+/\d+)\]([^\r\n]*)")

def run(cmd):
    pid, master_fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)

    buf = ""
    last_target = None
    try:
        while True:
            rfds, _, _ = select.select([master_fd], [], [])
            if master_fd in rfds:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                text = data.decode("utf-8", "replace")
                buf += text
                lines = buf.split("\n")
                buf = lines.pop()
                for line in lines:
                    line_clean = ansi_escape.sub("", line).replace("\r", "").strip()
                    m = prog_re.search(line_clean)
                    if m:
                        target = m.group(1)
                        if target != last_target:
                            last_target = target
                            sys.stdout.write(f"[{target}]{m.group(2)}\n")
                            sys.stdout.flush()
                    elif not line_clean.startswith("[local]") and not re.search(r"^\d+s\s+\[local\]", line_clean):
                        if line_clean:
                            sys.stdout.write(line_clean + "\n")
                            sys.stdout.flush()
    finally:
        os.close(master_fd)

    _, status = os.waitpid(pid, 0)
    if buf:
        line_clean = ansi_escape.sub("", buf).replace("\r", "").strip()
        if line_clean:
            sys.stdout.write(line_clean + "\n")
            sys.stdout.flush()

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1

if __name__ == "__main__":
    cmd = sys.argv[1:] if len(sys.argv) > 1 else ["./build.sh"]
    sys.exit(run(cmd))
