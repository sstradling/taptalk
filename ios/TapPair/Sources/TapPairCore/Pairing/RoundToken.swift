// Pairing/RoundToken.swift
//
// Round-scoped opaque token used by proximity providers and pair_evidence.
// Tokens must not reveal the persistent device id and should rotate every
// round. The BLE LocalName fallback in the prototype expects compact ASCII, so
// this generator emits 16 lowercase hex chars (64 bits).

import Foundation

public enum RoundToken {
    public static func generate() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    public static func isValid(_ token: String) -> Bool {
        token.count == 16 && token.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil
    }
}
