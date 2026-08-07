import Foundation

/**
 Whether a session is mid-turn, asked rather than assumed.

 On restart the board has to decide what a session that was `working` is doing *now*.
 It used to settle it to `idle`, on the reasoning that "nothing was happening while the
 app was closed". That is true of the app and false of the session: Claude Code is a
 separate process that kept going the whole time, and the app is only a light. Any
 session mid-turn during a relaunch came back saying nothing was happening.

 Both obvious fixes are guesses. Keeping `working` is wrong for a turn that finished
 while the app was down; settling to `idle` is wrong for one that did not. So neither
 is used — the transcript is read instead, because it says which it was.

 ## What the transcript shows

 Claude Code appends to `<session>.jsonl` as it goes, and the last conversational entry
 places you in the turn:

 - **`user`** → the assistant owes a reply. Either a human just typed, or a tool result
   just came back mid-turn. Working.
 - **`assistant` with `stop_reason: "tool_use"`** → it asked for a tool and is waiting
   on the answer. Still working.
 - **`assistant` with any other stop reason** — `end_turn`, `stop_sequence` — → the
   turn is finished and nothing is owed.

 ## Why the role alone is not enough

 The first version of this read only the role, on the reasoning that tool use
 alternates `assistant` then `user`, so an in-progress turn always ends on `user`. It
 does not: between asking for a tool and the result arriving — which is most of a long
 turn's wall-clock — the file ends on `assistant`.

 That was caught by checking against this machine's live transcript rather than the
 fixtures, which agreed with the wrong rule because I wrote both. Of 3,103 assistant
 entries in one session, 2,981 carry `tool_use`: the case the rule got wrong was the
 overwhelmingly common one.

 ## Read from the end

 A transcript runs to megabytes over a long session. Only the tail is needed, so only
 the tail is read — the file is seeked to its last few KB rather than parsed forward.
 */
public enum TurnState {
    /// How much of the tail to read. Comfortably more than one entry, small enough to
    /// be free: a single tool result with a large payload is the thing being cleared,
    /// and 64KB covers all but the extreme ones.
    static let tailBudget = 64 * 1024

    /// Whether the session is mid-turn, or nil when the transcript cannot answer.
    ///
    /// Nil is deliberately distinct from `false`. A missing, unreadable or truncated
    /// transcript is "no information", and the caller keeps whatever it already
    /// believed rather than acting on a guess dressed up as an answer.
    public static func isWorking(transcriptPath: String?) -> Bool? {
        guard let transcriptPath, !transcriptPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: transcriptPath)
        else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let offset = size > UInt64(tailBudget) ? size - UInt64(tailBudget) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        return isWorking(inTail: text, isWholeFile: offset == 0)
    }

    /**
     The same decision, on text — which is what the tests drive.

     - Parameter isWholeFile: whether the text starts at byte zero. If it does not, the
       first line is almost certainly cut in half and is dropped; keeping it would feed
       the parser a fragment, and a fragment that fails to parse is indistinguishable
       from a line of a type we do not care about.
     */
    public static func isWorking(inTail text: String, isWholeFile: Bool = true) -> Bool? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }

        // Backwards: the answer is the last entry that is part of the conversation.
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = entry["type"] as? String
            else { continue }

            // A subagent writes into the same file. Its turns are its own and say
            // nothing about whether the main thread is working — this is the same
            // exclusion the board makes when handing out keys.
            if entry["isSidechain"] as? Bool == true { continue }

            switch type {
            case "user": return true
            case "assistant":
                // Waiting on a tool is still working. A missing stop reason is treated
                // as finished: it is the conservative direction, since claiming a turn
                // is running is the error that leaves a key stuck.
                let reason = (entry["message"] as? [String: Any])?["stop_reason"] as? String
                return reason == "tool_use"
            // Summaries, meta entries and anything a future version adds are not turn
            // boundaries. Keep looking rather than treating an unknown as an answer.
            default: continue
            }
        }
        return nil
    }
}
