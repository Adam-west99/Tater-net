extends Reference

# Shared constants for the network protocol.

const PROTOCOL_VERSION = 2
const MOD_VERSION = "0.2.0"

# Steam P2P channels
const CH_CONTROL = 0   # reliable, gzip'd var2bytes dictionaries
const CH_SNAPSHOT = 1  # unreliable, chunked screen snapshots
const CH_INPUT = 2     # unreliable, client controller state

const MAX_PLAYERS = 4
# Remote players are registered with Brotato's CoopService as these device ids.
const DEVICE_BASE = 100

# Steam's legacy P2P API drops unreliable packets over 1200 bytes.
const CHUNK_PAYLOAD = 1100
# One XOR recovery chunk is sent per this many snapshot chunks.
const PARITY_GROUP = 4

# Primitive kinds in a snapshot
const K_SPRITE = 1
const K_TEXRECT = 2
const K_NINEPATCH = 3
const K_STYLEBOX = 4
const K_COLORRECT = 5
const K_LABEL = 6
const K_RICHTEXT = 7
const K_TEXPROGRESS = 8
const K_PROGRESSBAR = 9

# Controller buttons sent by clients. Values are Godot 3 joypad button indices.
const BUTTONS = [
	JOY_XBOX_A, JOY_XBOX_B, JOY_XBOX_X, JOY_XBOX_Y,
	JOY_L, JOY_R, JOY_L2, JOY_R2, JOY_L3, JOY_R3,
	JOY_SELECT, JOY_START,
	JOY_DPAD_UP, JOY_DPAD_DOWN, JOY_DPAD_LEFT, JOY_DPAD_RIGHT,
]


static func encode_control(data: Dictionary) -> PoolByteArray:
	return var2bytes(data).compress(File.COMPRESSION_GZIP)


static func decode_control(bytes: PoolByteArray):
	var raw = bytes.decompress_dynamic(-1, File.COMPRESSION_GZIP)
	if raw.size() == 0:
		return null
	var v = bytes2var(raw, false)  # never decode objects from the network
	return v if v is Dictionary else null
