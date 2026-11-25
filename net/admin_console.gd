# Owner console gate: the account server signs "console|<username>|<expiry>" (RSA-SHA256, key kept on the VM)
# for the owner's account only; the game embeds the public key (net/admin_pub.pem) and checks the signature.
class_name AdminConsole
extends RefCounted

const PUB := "res://net/admin_pub.pem"


## The username in a valid, unexpired token, else "".
static func check(payload: String, sig_b64: String, now_unix := -1.0) -> String:
	var parts := payload.split("|")
	if parts.size() != 3 or parts[0] != "console" or not parts[2].is_valid_int():
		return ""
	var now := Time.get_unix_time_from_system() if now_unix < 0.0 else now_unix
	if float(int(parts[2])) < now:
		return ""
	var pem := FileAccess.get_file_as_string(PUB)
	if pem.is_empty():
		return ""
	var key := CryptoKey.new()
	if key.load_from_string(pem, true) != OK:
		return ""
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(payload.to_utf8_buffer())
	var sig := Marshalls.base64_to_raw(sig_b64)
	if sig.is_empty():
		return ""
	if not Crypto.new().verify(HashingContext.HASH_SHA256, hc.finish(), sig, key):
		return ""
	return parts[1]


## The signed token saved on this device ({payload, sig}) when it is valid, else {}.
static func saved(settings: Dictionary) -> Dictionary:
	var t = settings.get("admin_token")
	if t is Dictionary and check(str(t.get("payload", "")), str(t.get("sig", ""))) != "":
		return t
	return {}
