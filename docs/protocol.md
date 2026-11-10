# touchytua — protocollo Mac ↔ iPhone (v1)

## Pairing (QR)
`touchytua://pair?d=<base64url senza padding di JSON PairingPayload>`

| Campo | Tipo | Note |
|---|---|---|
| `v` | int | `1` |
| `macKey` | bytes (base64 in JSON) | chiave statica X25519 pubblica del Mac, 32 B |
| `secret` | bytes | segreto monouso, 32 B; invalidato dopo il primo handshake riuscito o dopo 10 minuti |
| `endpoints` | [string] | `lan:<host>:<port>`, `ts:<name>.ts.net:<port>` |
| `macName` | string | nome leggibile |

## Handshake (per connessione)
1. Telefono → Mac: `Hello { phoneKey, ephemeral, proof?, v }` (JSON).
   - `proof = HMAC-SHA256(secret, phoneKey || ephemeral)`, solo al primo pairing.
   - `v` è la versione del protocollo (oggi `1`; assente vale `1`).
2. Il Mac accetta:
   - un hello **con** `proof`, se è valido per il segreto del QR ancora attivo: è un nuovo pairing e sostituisce il telefono precedente;
   - un hello **senza** `proof`, solo se `phoneKey` è quella salvata. Vale anche mentre un QR aspetta di essere scansionato.
   - Altrimenti chiude la connessione (`badSecret` / `unknownPeer`).
3. Mac → telefono: `Reply { ephemeral, v }`.
4. Chiavi:
   - `ikm = DH(e_mac, e_phone) || DH(s_mac, s_phone)`
   - `K_dir = HKDF-SHA256(ikm, salt = "touchytua-v1" || secret?, info = dir || s_mac || s_phone || e_mac || e_phone, 32 B)`
   - `dir` è `"phone->mac"` oppure `"mac->phone"`; le quattro chiavi pubbliche (32 B ciascuna) legano le chiavi a questo scambio.
   - `secret` entra nel salt solo al primo pairing.

Il DH statico-statico autentica entrambe le parti; gli effimeri danno forward secrecy.

## Frame
`counter (UInt64 BE, 8 B) || ChaCha20-Poly1305(ciphertext || tag 16 B)`.
- Nonce = `00 00 00 00 || counter`.
- Il counter parte da 1 e cresce per direzione: un frame con counter ≤ ultimo ricevuto viene rifiutato (replay).

## Messaggi (JSON dentro i frame, discriminante `"t"`)
Definiti in `TouchyKit/Messages.swift`.

| Direzione | `t` |
|---|---|
| telefono → Mac | `hello`, `decide`, `answer`, `prompt` |
| Mac → telefono | `snapshot`, `session`, `sessionRemoved`, `request`, `requestResolved`, `usage`, `error` |

- Le date sono secondi dal 2001-01-01 UTC (numero).
- Plugin e app si aggiornano separatamente: un `t` sconosciuto **non** chiude la connessione. Il telefono lo ignora; il Mac risponde `error` con `code = "unsupported_message"`.
- Codici di `error`: `unknown_request`, `unknown_session`, `inject_failed`, `unsupported_message`, `bad_message`.
- Il Mac invia `session` solo quando cambia qualcosa di visibile (stato, titolo, round), non a ogni tool call.
