import CryptoKit
import Foundation

// Whether signature, from the key whose X9.63 public key is publicKey, signs message.
func verifySignature(_ signature: Data, of message: Data, publicKey: Data) -> Bool {
    guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
          let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
    return key.isValidSignature(sig, for: message)
}

func isPublicKey(_ key: Data) -> Bool {
    (try? P256.Signing.PublicKey(x963Representation: key)) != nil
}

// The helper's check of a pairing request: the caller is an administrator, who just approved it, and its proof is
// signed with its own read key, answering a challenge from challenges, which it then spends. Only administrators pair,
// since nylon's config can run commands as root; every one enrolls the same way, the first after an install too.
func checkPairing(keys: PairingKeys, keysData: Data, challenge: Data, proof: Data, challenges: inout Challenges,
                  caller: Caller, approved: Bool) throws {
    guard isPublicKey(keys.read), isPublicKey(keys.write) else { throw Failure("Bad keys.") }
    guard verifySignature(proof, of: pairingMessage(challenge: challenge, keys: keysData), publicKey: keys.read) else {
        throw Failure("The request to connect wasn't signed with its own key.")
    }
    guard challenges.spend(challenge) else { throw Failure("The request to connect has a challenge that's used, expired or from another connection.") }
    guard caller.isAdministrator else { throw Failure("Only an administrator's account can control nylon's helper.") }
    guard approved else { throw Failure("An administrator has to approve connecting.") }
}

// The helper's check of a signed request: from one of the caller's pairings, signed with that pairing's key for its
// action, answering a challenge from challenges, which it then spends. Changes also need the caller to still be an
// administrator, so taking someone out of the admin group takes away their control. Returns the pairing and action.
func checkRequest(_ request: Data, signature: Data, challenges: inout Challenges, pairings: [Pairing], caller: Caller) throws
    -> (Pairing, HelperAction) {
    guard let signed = try? decodeJSON(SignedRequest.self, request) else { throw Failure("Bad request.") }
    guard let pairing = pairings.first(where: { $0.keys.read == signed.pairing && $0.uid == caller.uid }) else {
        throw Failure("This app isn't connected to the nylon helper.")
    }
    let key = signed.action.needsWriteKey ? pairing.keys.write : pairing.keys.read
    guard verifySignature(signature, of: request, publicKey: key) else { throw Failure("The app's signature doesn't match its connection.") }
    guard challenges.spend(signed.challenge) else { throw Failure("The request's challenge is used, expired or from another connection.") }
    guard caller.isAdministrator || !signed.action.needsWriteKey else {
        throw Failure("Only an administrator's account can change nylon's networks.")
    }
    return (pairing, signed.action)
}

// The challenges one connection has issued and not yet seen used. Each is good once, for a minute, and only a few
// are open at a time: the app asks for one per request, and a few requests can be in flight.
struct Challenges {
    private var issued: [Data: Date] = [:]
    static let lifetime: TimeInterval = 60
    static let limit = 16

    mutating func issue(now: Date = Date()) -> Data {
        expire(now)
        if issued.count >= Self.limit, let oldest = issued.min(by: { $0.value < $1.value }) { issued[oldest.key] = nil }
        let challenge = randomBytes(32)
        issued[challenge] = now
        return challenge
    }

    // Spends challenge if it's open. Returns whether it was.
    mutating func spend(_ challenge: Data, now: Date = Date()) -> Bool {
        expire(now)
        return issued.removeValue(forKey: challenge) != nil
    }

    private mutating func expire(_ now: Date) {
        issued = issued.filter { now.timeIntervalSince($0.value) < Self.lifetime }
    }
}
