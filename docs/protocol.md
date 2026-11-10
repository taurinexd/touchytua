# touchytua — protocollo Mac ↔ iPhone (v1)

## Pairing (QR)
`touchytua://pair?d=<base64url senza padding di JSON PairingPayload>`

| Campo | Tipo | Note |
|---|---|---|
| `v` | int | `1` |
| `macKey` | bytes (base64 in JSON) | chiave statica X25519 pubblica del Mac, 32 B |
| `secret` | bytes | segreto monouso, 32 B; invalidato dopo il primo handshake riuscito |
| `endpoints` | [string] | `lan:<host>:<port>`, `ts:<name>.ts.net:<port>` |
| `macName` | string | nome leggibile |

## Handshake (per connessione)
1. Telefono → Mac: `Hello { phoneKey, ephemeral, proof? }` (JSON).
   - `proof = HMAC-SHA256(secret, phoneKey || ephemeral)`, solo al primo pairing.
2. Il Mac accetta:
   - al primo pairing, se `proof` è valido per `secret`;
   - dopo, solo se `phoneKey` è quella salvata.
   - Altrimenti chiude la connessione (`badSecret` / `unknownPeer`).
3. Mac → telefono: `Reply { ephemeral }`.
4. Chiavi:
   - `ikm = DH(e_mac, e_phone) || DH(s_mac, s_phone)`
   - `K_dir = HKDF-SHA256(ikm, salt = "touchytua-v1" || secret?, info = "phone->mac" | "mac->phone", 32 B)`
   - `secret` entra nel salt solo al primo pairing.

Il DH statico-statico autentica entrambe le parti; gli effimeri danno forward secrecy.

## Frame
`counter (UInt64 BE, 8 B) || ChaCha20-Poly1305(ciphertext || tag 16 B)`.
- Nonce = `00 00 00 00 || counter`.
- Il counter parte da 1 e cresce per direzione: un frame con counter ≤ ultimo ricevuto viene rifiutato (replay).

## Messaggi (JSON dentro i frame, discriminante `"t"`)
Definiti in `TouchyKit/Messages.swift` (Task 7).
