import Foundation

/**
 Decides whether a Claude Code session may consume one of the six Agent keys.

 Ported from `lib/eligibility.cjs` rule for rule, including the order the checks run
 in — a subagent belonging to an embedded SDK client should report as a subagent,
 because that is the more specific and more useful answer.

 **Fail-closed by design.** An unrecognised surface gets no light rather than
 quietly stealing one. Six keys is a scarce budget and it belongs to sessions a human
 is actually sitting in front of. The failure mode being avoided is real and was
 observed: ten `claude` processes under an unrelated VS Code extension, all running
 with `--setting-sources=user` so user-level hooks fired for every one of them. Without
 the allowlist they would have taken all six keys before a human session appeared.

 Every value here was observed from real sessions rather than taken from a schema.
 */
public enum Eligibility {
    /// Surfaces that get a key. Everything else does not, including things that
    /// simply have not been observed yet — new surfaces must be added deliberately.
    public static let defaultEntrypoints: Set<String> = ["cli", "claude-vscode"]

    public struct Verdict: Equatable, Sendable {
        public let eligible: Bool
        public let reason: Reason
        public let detail: String

        public init(eligible: Bool, reason: Reason, detail: String) {
            self.eligible = eligible
            self.reason = reason
            self.detail = detail
        }
    }

    public enum Reason: String, Equatable, Sendable {
        case ok
        case subagent
        case embeddedSDK = "embedded-sdk"
        case unknownEntrypoint = "unknown-entrypoint"
        case entrypointNotAllowed = "entrypoint-not-allowed"
        case noSessionID = "no-session-id"
    }

    /// The hook payload fields that bear on eligibility.
    public struct Payload: Sendable {
        public var sessionID: String?
        public var agentID: String?
        public var agentType: String?

        public init(sessionID: String? = nil, agentID: String? = nil, agentType: String? = nil) {
            self.sessionID = sessionID
            self.agentID = agentID
            self.agentType = agentType
        }
    }

    /// Resolve the allowlist. Precedence matches the Node version: an environment
    /// override beats configuration, which beats the built-in default. An override
    /// that resolves to nothing falls back rather than locking every session out.
    public static func allowedEntrypoints(
        env: [String: String],
        configured: [String]? = nil
    ) -> Set<String> {
        let raw = env["OPENBOARD_ENTRYPOINTS"] ?? configured?.joined(separator: ",") ?? ""
        let values = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? defaultEntrypoints : Set(values)
    }

    public static func evaluate(
        env: [String: String],
        payload: Payload = Payload(),
        configured: [String]? = nil,
        harness: String? = nil
    ) -> Verdict {
        // Subagents first. Codex excludes these from slot eligibility too; a single
        // parallel fan-out would otherwise exhaust all six keys at once.
        if let type = payload.agentType, !type.isEmpty {
            return Verdict(eligible: false, reason: .subagent, detail: "agent_type=\(type)")
        }
        if let id = payload.agentID, !id.isEmpty {
            return Verdict(eligible: false, reason: .subagent, detail: "agent_id set")
        }
        if env["CLAUDE_AGENT_ID"] != nil || env["CLAUDE_AGENT_TYPE"] != nil {
            return Verdict(eligible: false, reason: .subagent, detail: "subagent environment")
        }

        // Embedded Agent SDK consumers: not ours, and not interactive.
        if let client = env["CLAUDE_AGENT_SDK_CLIENT_APP"], !client.isEmpty {
            return Verdict(eligible: false, reason: .embeddedSDK, detail: "client_app=\(client)")
        }

        /*
         Another harness, which the entry-point allowlist below cannot speak about.

         `CLAUDE_CODE_ENTRYPOINT` is Claude Code's variable. Hermes and Pi do not set it
         and never will, so applying the allowlist to their events would refuse every
         one of them as an unknown surface — a fail-closed rule doing exactly its job on
         a question it was not asked.

         Which harness sent an event is not guessed from the payload: the hook command
         says so, because the command is ours to write. Everything above still applies —
         a subagent is a subagent whoever spawned it — and a session id is still
         required below.
        */
        if let harness, harness != Harness.claudeCode.id {
            guard Harness.all.contains(where: { $0.id == harness }) else {
                return Verdict(
                    eligible: false,
                    reason: .unknownEntrypoint,
                    detail: "unknown harness=\(harness)"
                )
            }
            guard let sessionID = payload.sessionID, !sessionID.isEmpty else {
                return Verdict(
                    eligible: false,
                    reason: .noSessionID,
                    detail: "payload missing session_id"
                )
            }
            _ = sessionID
            return Verdict(eligible: true, reason: .ok, detail: "harness=\(harness)")
        }

        guard let entrypoint = env["CLAUDE_CODE_ENTRYPOINT"], !entrypoint.isEmpty else {
            return Verdict(
                eligible: false,
                reason: .unknownEntrypoint,
                detail: "CLAUDE_CODE_ENTRYPOINT unset"
            )
        }
        guard allowedEntrypoints(env: env, configured: configured).contains(entrypoint) else {
            return Verdict(
                eligible: false,
                reason: .entrypointNotAllowed,
                detail: "entrypoint=\(entrypoint)"
            )
        }

        guard let sessionID = payload.sessionID, !sessionID.isEmpty else {
            return Verdict(
                eligible: false,
                reason: .noSessionID,
                detail: "payload missing session_id"
            )
        }
        _ = sessionID

        return Verdict(eligible: true, reason: .ok, detail: "entrypoint=\(entrypoint)")
    }
}
