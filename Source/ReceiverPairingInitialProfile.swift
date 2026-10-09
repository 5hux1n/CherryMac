import Foundation

// Explicit port of the fixed Utility's *initial* model registry values. It is
// not a selector read from hardware or an assertion about all Windows runtime
// mutations. Callers must deliberately choose this profile; the wire adapter
// still has no default selector and this object cannot authorize any report.
struct ReceiverPairingInitialProfile {
    struct Evidence:Encodable {
        let profileID:String
        let executableSHA256:String
        let origin:String
        let keyboardRegistryRows:[Int]
        let receiverRegistryRows:[Int]
        let keyboardSelector:UInt16
        let receiverSelector:UInt16
        let hardwareReadbackVerified:Bool
    }
    static let profileID="pokemon47-official-initial-a92412c6"
    static let executableSHA256="a92412c6e3bd05d722c30e0d1ab1762570934b28bd31ea482ad2b51ce187f396"
    let selection:ReceiverPairingSelection
    init(selection:ReceiverPairingSelection)throws{
        try selection.validate();self.selection=selection
    }
    var evidence:Evidence{
        .init(profileID:Self.profileID,executableSHA256:Self.executableSHA256,
            origin:"Fixed Utility initial registry metadata word+0x9c; not live hardware readback",
            keyboardRegistryRows:[126,127,128],receiverRegistryRows:[129,130,131],
            keyboardSelector:0,receiverSelector:0,hardwareReadbackVerified:false)
    }
    func selector(_ endpoint:ReceiverPairingFrames.Endpoint,current:ReceiverPairingSelection)throws->UInt16{
        try current.validate()
        guard current==selection else{throw ReceiverPairingSelection.SelectionError.staleSelection}
        switch endpoint {
        case .keyboard:return evidence.keyboardSelector
        case .receiver:return evidence.receiverSelector
        }
    }
    func plan(_ phase:ReceiverPairingTransaction.Phase,current:ReceiverPairingSelection)throws->ReceiverPairingFrames.Plan{
        try current.validate()
        guard current==selection else{throw ReceiverPairingSelection.SelectionError.staleSelection}
        let endpoint:ReceiverPairingFrames.Endpoint=phase == .keyboardStart ? .keyboard:.receiver
        return try ReceiverPairingFrames.plan(phase:phase,selector:phase == .polling ? nil:selector(endpoint,current:current))
    }
}
