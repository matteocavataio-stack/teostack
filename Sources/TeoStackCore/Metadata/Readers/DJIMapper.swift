import Foundation

/// Dati dei DJI registrati nel flusso «djmd» (protobuf) dei MOV/MP4, letti da ExifTool con `-ee`.
///
/// ExifTool non dà un nome ai campi di questo protocollo: li chiama con la loro posizione («Dvtm_fc4280_<percorso>»). Qui si usano SOLO le posizioni
/// del protocollo `dvtm_fc4280.proto` (DJI Inspire 3 / FC4280) il cui significato è confermato dal CONTENUTO del campo stesso o dal confronto con altri
/// dati dello stesso clip (verificato su un clip ProRes RAW e su un fotogramma CinemaDNG dello stesso modello):
/// - `1-3-1` «A» = indice camera; `1-3-2` «A005_4U1Q» = reel; `1-3-4` nome del clip;
/// - `2-2-2-1-4` modello della lente; `2-2-2-2-1` seriale della lente;
/// - `2-2-3-1` seriale della camera (stessa forma del `CameraSerialNumber` dei DNG); `2-2-4-2` firmware della camera (stessa forma del «Software» dei DNG);
/// - `2-2-11-1` gamma («D-Log»).
/// Altri protocolli DJI (altri modelli) non vengono interpretati: i loro tag restano in `rawFields`. Valori del PRIMO campione del flusso.
enum DJIMapper {
    static let protocolMarker = "Dvtm_fc4280_"

    static func enrich(_ file: ClipFile, _ m: inout ClipMetadata) {
        guard m.container == "QuickTime", file.hasEmbeddedReader,
              m.rawFields.keys.contains(where: { $0.hasSuffix(":HandlerDescription") && m.rawFields[$0] == "DJI meta" }),
              let tags = try? file.exifEmbeddedTags() else { return }
        let b = TagBag(tags: tags)
        guard tags.keys.contains(where: { $0.contains(protocolMarker) }) else {
            m.rawFields.merge(RawTags.fields(from: tags)) { a, _ in a }
            return
        }
        func v(_ position: String) -> String? { ExifMapper.real(b.string(protocolMarker + position)) }
        if let idx = v("1-3-1") { m.extraColumns["cameraIndex"] = idx }
        if m.reel == nil { m.reel = v("1-3-2") }
        if m.clipName == nil { m.clipName = v("1-3-4") }
        if m.lensModel == nil { m.lensModel = v("2-2-2-1-4") }
        if m.extraColumns["lensSerial"] == nil, let s = v("2-2-2-2-1") { m.extraColumns["lensSerial"] = s }
        if m.cameraSerial == nil { m.cameraSerial = v("2-2-3-1") }
        if m.firmware == nil { m.firmware = v("2-2-4-2") }
        if m.gamma == nil { m.gamma = v("2-2-11-1") }
        // tutti i tag del flusso, in aggiunta agli altri (senza sovrascrivere)
        m.rawFields.merge(RawTags.fields(from: tags)) { a, _ in a }
        m.status = .read
    }
}
