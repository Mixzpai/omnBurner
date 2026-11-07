## Painting the app: entering and leaving the full-screen terminal, the modal
## dialogs, and handing each screen to its draw proc (in `drawimage` and
## `drawjob`).

from std/strutils import repeat
from std/unicode import runeLen
import ../[sudoauth, term]
import screen, widgets
import state
import drawimage, drawjob

# ---------------------------------------------------------------------------
# Terminal

proc enterScreen*(a: App) =
  enableRaw()
  stdout.write "\e[?1049h\e[?25l"
  stdout.flushFile()
  a.prev = newBuffer(0, 0)

proc leaveScreen*() =
  stdout.write "\e[0m\e[?25h\e[?1049l"
  stdout.flushFile()
  disableRaw()

proc draw(a: App, b: var Buffer)

proc drawNow*(a: App) =
  let (w, h) = termSize(1)
  var b = newBuffer(w, h)
  b.clear()
  a.draw(b)
  stdout.write a.prev.flush(b)
  stdout.flushFile()

# ---------------------------------------------------------------------------
# Modals, and which screen to draw

proc passwordLines(a: App): seq[seq[Seg]] =
  ## The password box's text. The field goes on the empty line after the label.
  let au = a.auth
  let label =
    if au.done and au.ok: "sudo doesn't need your password for this."
    elif au.prompt.len > 0: au.prompt # one of PAM's own, like a one-time code
    else: "Enter your password to become root with sudo:"
  let status: seq[Seg] =
    if au.checking: @[("Checking…", a.dim)]
    elif au.wrong: @[((if au.said.len > 0: au.said else: "Wrong password, try again."), a.bad)]
    elif au.done and not au.ok:
      @[((if au.said.len > 0: au.said else: "sudo gave up."), a.bad), ("  ⏎ tries again", a.dim)]
    elif not au.asking and au.said.len > 0: @[(au.said, a.dim)] # e.g. a fingerprint reader
    else: @[]
  @[@[("omnBurn doesn't have permission to write to", a.fg)],
    @[(a.jobTargets.names.ellipsizeLeft(58), a.bright)],
    @[],
    @[(label, a.fg)],
    @[],
    status,
    @[],
    @[("⏎", a.acc), (" continue   ", a.fg), ("esc", a.acc), (" cancel", a.fg)]]

proc drawModal(a: App, b: var Buffer) =
  case a.modal
  of mdNone: discard
  of mdQuit:
    b.modal("Stop?", [@[("Are you sure you want to quit? The drive will be left", a.fg)],
                      @[("half written. ", a.fg), ("q", a.acc), (" quits, ", a.fg), ("esc", a.acc),
                        (" keeps going.", a.fg)]], a.th, a.th.red)
  of mdStopDownload:
    b.modal("Stop the download?", [@[("The partial file is kept, so it can resume later.", a.fg)],
                                   @[("y", a.acc), (" stops, ", a.fg), ("esc", a.acc), (" keeps going.", a.fg)]],
            a.th, a.th.yellow)
  of mdEscalate:
    b.modal("Root needed", [@[("omnBurn doesn't have permission to write to", a.fg)],
                            @[(a.jobTargets.names.ellipsizeLeft(58), a.bright)],
                            @[("Become root with " & $a.escMethod & "? It may ask for your password.", a.fg)],
                            @[],
                            @[("y", a.acc), (" yes   ", a.fg), ("n", a.acc), (" no", a.fg)]],
            a.th, a.th.accent)
  of mdPassword:
    let lines = a.passwordLines
    b.modal("Root needed", lines, a.th, a.th.accent)
    if not (a.auth.done and a.auth.ok):
      let w = min(64, b.w - 4)
      let r = centered(rect(0, 0, b.w, b.h), w, lines.len + 4)
      b.textField(r.x + 2, r.y + 6, r.w - 4, "•".repeat(a.password.runeLen), a.th,
                  active = not a.auth.checking)
  of mdTypeConfirm:
    let need = a.confirmText
    let lines = @[@[("Type ", a.fg), (need, a.bright), (" to confirm that you want to", a.fg)],
                  @[("destroy everything on it:", a.fg)], @[], @[]]
    b.modal("Are you really sure?", lines, a.th, a.th.red)
    let w = min(64, b.w - 4)
    let r = centered(rect(0, 0, b.w, b.h), w, lines.len + 4)
    b.textField(r.x + 2, r.y + 5, r.w - 4, a.typed, a.th)

proc draw(a: App, b: var Buffer) =
  case a.screen
  of scHome: a.drawHome(b)
  of scBrowse: a.drawBrowse(b)
  of scDownload: a.drawDownload(b)
  of scWindows: a.drawWindows(b)
  of scUrl: a.drawUrl(b)
  of scFetching: a.drawFetching(b)
  of scImage: a.drawImage(b)
  of scHashing: a.drawHashing(b)
  of scDisks: a.drawDisks(b)
  of scBackupOpts: a.drawBackupOpts(b)
  of scRestoreOpts: a.drawRestoreOpts(b)
  of scConfirm: a.drawConfirm(b)
  of scRun: a.drawRun(b)
  of scDone: a.drawDone(b)
  a.drawModal(b)
