class_name RadioPhrases
extends RefCounted
## The pit wall's recorded voice: short clips baked by
## tools/radio_voice_bake.py into voice/<voice>/ (a neural voice, Kokoro,
## Apache 2.0), with an index phrases.json of {key: {file, s}}. A message is
## built from the longest clips that match it, whole lines where there are
## any ("Box, box. Box this lap.") and pieces for numbers ("Pressures" +
## "front left" + "twenty seven" + "point five" + "psi"), with short pauses
## where the text has commas and full stops. Used by RadioVoice.

const VOICE_DIR := "res://modules/audio/voice/"
const VOICES := ["engineer_male", "engineer_female"]
const LONGEST := 16                 ## most words in one clip
const GAP_WORD := 0.03              ## seconds between pieces of one sentence
const GAP_COMMA := 0.14
const GAP_STOP := 0.26

const ONES := ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
	"eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
const TENS := ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

static var _banks := {}


## A voice's index {key: {file, s}} (empty when that voice isn't there).
static func bank(voice: String) -> Dictionary:
	if _banks.has(voice):
		return _banks[voice]
	var b := {}
	var path := VOICE_DIR + voice + "/phrases.json"
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			b = data.get("phrases", {})
	_banks[voice] = b
	return b


## Lower case words, no punctuation: how clips are looked up.
static func key_of(text: String) -> String:
	var t := text.to_lower().replace("-", " ")
	var out := ""
	for ch in t:
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "'" else " "
	return " ".join(out.split(" ", false))


## 0..999 in words, the way the clips were baked ("one hundred and five").
static func number_words(n: int) -> String:
	if n < 20:
		return ONES[n]
	if n < 100:
		return TENS[n / 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
	var rest := n % 100
	return ONES[n / 100] + " hundred" + ("" if rest == 0 else " and " + number_words(rest))


## Writes the numbers in a message out as words: "27.5" -> "twenty seven
## point five", "26.0" -> "twenty six".
static func expand_numbers(text: String) -> String:
	var re := RegEx.create_from_string("\\d+(\\.\\d+)?")
	var out := ""
	var at := 0
	for m in re.search_all(text):
		out += text.substr(at, m.get_start() - at)
		var parts := m.get_string().split(".")
		var whole := int(parts[0])
		var words := number_words(whole) if whole < 1000 else parts[0]
		if parts.size() > 1 and int(parts[1]) != 0:
			words += " point"
			for d in parts[1].rstrip("0"):
				words += " " + ONES[int(d)]
		out += words
		at = m.get_end()
	return out + text.substr(at)


## The clips that say a message, in order: [[file path, length s, pause after s], ...],
## or [] when some word has no clip (the caller falls back to the computer's voice).
static func compose(text: String, voice: String) -> Array:
	var b := bank(voice)
	if b.is_empty():
		return []
	var words: Array[String] = []
	var pause: Array[float] = []
	var re := RegEx.create_from_string("[A-Za-z0-9']+|[.,:;?!]")
	for m in re.search_all(expand_numbers(text).replace("-", " ")):
		var tok := m.get_string()
		if tok in [".", "?", "!", ":", ";", ","]:
			if not pause.is_empty():
				pause[-1] = maxf(pause[-1], GAP_COMMA if tok == "," else GAP_STOP)
		else:
			words.append(tok.to_lower())
			pause.append(GAP_WORD)
	if words.is_empty():
		return []
	var clips := []
	var i := 0
	while i < words.size():
		var found := false
		for j in range(mini(words.size(), i + LONGEST), i, -1):
			var k := " ".join(words.slice(i, j))
			if b.has(k):
				var e: Dictionary = b[k]
				clips.append([VOICE_DIR + voice + "/" + str(e["file"]), float(e["s"]), pause[j - 1]])
				i = j
				found = true
				break
		if not found:
			return []
	return clips


## True when every word of the message has a clip in this voice.
static func can_say(text: String, voice: String) -> bool:
	return not compose(text, voice).is_empty()
