const tui = @import("../tui.zig");
const session_mod = @import("session.zig");
const runs_ui = @import("runs_ui.zig");

const Session = session_mod.Session;

pub fn scrollbackKey(sess: *Session, ev: tui.Event) bool {
    switch (ev) {
        .esc => {
            runs_ui.blurScrollback(sess);
            return true;
        },
        .tab, .shift_tab => {
            runs_ui.blurScrollback(sess);
            return true;
        },
        .down => {
            if (!sess.moveChild(false)) runs_ui.moveSel(sess, false);
            return true;
        },
        .up => {
            if (!sess.moveChild(true)) runs_ui.moveSel(sess, true);
            return true;
        },
        .right => {
            runs_ui.setExpanded(sess, true);
            return true;
        },
        .left => {
            runs_ui.setExpanded(sess, false);
            return true;
        },
        .enter => {
            // Inside an open run, Enter belongs to the call the cursor is on.
            if (runs_ui.toggleChild(sess)) return true;
            runs_ui.setExpanded(sess, null);
            return true;
        },
        // Scroll without moving the selection: reading around a run should not
        // cost you your place in it.
        .ctrl_j => {
            if (sess.bumpScroll(false, 1)) sess.dirty = true;
            return true;
        },
        .kill_line => {
            if (sess.bumpScroll(true, 1)) sess.dirty = true;
            return true;
        },
        .ctrl_d => {
            if (sess.bumpScroll(false, @max(1, sess.layout.transcript_rows / 2))) sess.dirty = true;
            return true;
        },
        .kill_to_start => {
            if (sess.bumpScroll(true, @max(1, sess.layout.transcript_rows / 2))) sess.dirty = true;
            return true;
        },
        .shift_right => {
            runs_ui.selectTurn(sess, false);
            return true;
        },
        .shift_left => {
            runs_ui.selectTurn(sess, true);
            return true;
        },
        .byte => |b| switch (b) {
            'j' => {
                if (!sess.moveChild(false)) runs_ui.moveSel(sess, false);
                return true;
            },
            'k' => {
                if (!sess.moveChild(true)) runs_ui.moveSel(sess, true);
                return true;
            },
            'e' => {
                runs_ui.setExpanded(sess, null);
                return true;
            },
            'l' => {
                runs_ui.setExpanded(sess, true);
                return true;
            },
            'h' => {
                runs_ui.setExpanded(sess, false);
                return true;
            },
            'g' => {
                runs_ui.selectEnd(sess, false);
                return true;
            },
            'G' => {
                runs_ui.selectEnd(sess, true);
                return true;
            },
            'E' => {
                runs_ui.expandAll(sess);
                return true;
            },
            'n' => {
                if (runs_ui.stepHunk(sess, true)) return true;
                return false;
            },
            'p' => {
                if (runs_ui.stepHunk(sess, false)) return true;
                return false;
            },
            'y' => {
                runs_ui.copyRun(sess);
                return true;
            },
            'q' => {
                runs_ui.blurScrollback(sess);
                return true;
            },
            // Space hands the keyboard back without typing a space, the way
            // it does in grok-build: reading is a mode you leave, not a key
            // you have to remember.
            ' ' => {
                runs_ui.blurScrollback(sess);
                return true;
            },
            'Y' => {
                runs_ui.copyRunOutput(sess);
                return true;
            },
            else => {
                runs_ui.blurScrollback(sess);
                return false;
            },
        },
        else => return false,
    }
}
