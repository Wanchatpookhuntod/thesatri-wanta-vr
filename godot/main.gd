extends Node3D
## เมืองที่สร้างจากเสียง: Godot VR prototype of the guided-play mode from the web version (index.html).
## A ระนาดเอก within arm's reach, a mallet in each hand, synthesised ระนาด/ฆ้อง/ฉิ่ง, guide lights that travel
## down a lane to each key and land on the beat, a teacher who plays any note the player misses, and a combo.
## With no headset (OpenXR not started) it falls back to a desktop camera: click keys or press 1–0 q w e r.

const KEYS := 14
const KEYMAP := "1234567890qwer"
const APPROACH := 2.0        # seconds a guide light is visible before its beat
const HIT_WIN := 0.2         # a strike within this many seconds of the beat counts
const PERFECT_WIN := 0.08
const STEP := 0.44           # seconds per step of the melody
const LANE_LEN := 1.4
const LANE_RISE := 0.28
const HEAD_R := 0.017
const MIN_DOWN_SPEED := 0.25
const RATE := 24000        # synthesis sample rate; low enough that start-up synthesis stays quick
const RANAT_POS := Vector3(0, 0.9, -0.5)
const GUIDE_COLORS := [Color("ff4a3d"), Color("ffe14a"), Color("ff6fb5"), Color("4cff7a"), Color("ff9a2e"), Color("4ab8ff"), Color("a86bff")]
const KEY_GLOW := Color("ffb050")

# ⚠ ทำนองชั่วคราว (ต้นแบบ) เหมือนเว็บ: one token per step, 4 per ห้อง.
#   ด ร ม ฟ ซ ล ท = notes, ' = upper octave, - = rest, ~ = กรอ on the previous note, | = ห้อง separator (ignored)
const MELODY := """
ล ซ ม ร  ม ซ ล ร'  ด' ล ซ ล  ด' ร' ม' ร'  |  ด' ล ด' ร'  ม' ซ' ล' ซ'  ม' ร' ด' ล  ด' ล ซ ~
ร' ด' ล ด'  ร' ม' ร' ด'  ล ซ ม ซ  ล ด' ล ซ  |  ม ร ม ซ  ล ซ ม ร  ด ร ม ร  ด ~ ด ~
ม ซ ล ร'  ด' ล ซ ม  ซ ล ด' ม'  ร' ด' ล ซ  |  ล ด' ร' ซ'  ม' ร' ด' ล  ด' ร' ม' ล'  ซ' ม' ร' ~
ซ' ม' ร' ด'  ร' ม' ซ' ม'  ร' ด' ล ซ  ล ด' ร' ด'  |  ล ซ ม ร  ม ซ ล ซ  ม ร ด ร  ม ~ ม ~
"""
const NOTE := {"ด": 0, "ร": 1, "ม": 2, "ฟ": 3, "ซ": 4, "ล": 5, "ท": 6}
const REST := -2
const ROLL := -1


class RanatKey:
	var i: int
	var x: float
	var y0: float
	var length: float
	var mesh: MeshInstance3D
	var mat: StandardMaterial3D
	var flash := 0.0
	var hit := 0.0
	var guide := 0.0


class Guide:
	var key: int
	var t: float
	var vel: float
	var orb: MeshInstance3D
	var mat: StandardMaterial3D
	var state := ""            # "" waiting, "hit", "miss"
	var done_t := 0.0
	var teacher := false       # the teacher has played this beat


class Mallet:
	var ctrl: XRController3D
	var head: Node3D
	var ready := false
	var prev := Vector3.ZERO
	var prev_loc := Vector3.ZERO
	var last_hit := -1
	var last_t := 0.0


class Fx:
	var node: MeshInstance3D
	var mat: StandardMaterial3D
	var t0: float
	var dur: float
	var grow: float
	var rise: float


var xr_on := false
var desk_cam: Camera3D
var ranat: Node3D
var keys: Array[RanatKey] = []
var lane_start: Array[Vector3] = []
var lane_end: Array[Vector3] = []
var lane_mats: Array[StandardMaterial3D] = []
var mallets: Array[Mallet] = []
var guides: Array[Guide] = []
var fxs: Array[Fx] = []
var events: Array[Dictionary] = []

var note_streams: Array[AudioStreamWAV] = []
var chime_streams: Array[AudioStreamWAV] = []
var chime5_streams: Array[AudioStreamWAV] = []
var gong_stream: AudioStreamWAV
var ching_open: AudioStreamWAV
var ching_closed: AudioStreamWAV
var players: Array[AudioStreamPlayer] = []
var next_player := 0

var phrases: Array = []
var phrase_idx := 0
var pos := 0
var step_i := 0
var last_key := 4
var t0_usec := 0
var next_t := 2.0
var combo := 0
var label: Label3D
var label_t := -9.0
var label_word := ""
var font: Font


func _ready() -> void:
	font = load("res://fonts/Loma-Bold.otf")
	var xr_if := XRServer.find_interface("OpenXR")
	if xr_if and xr_if.is_initialized():
		get_viewport().use_xr = true
		xr_on = true
	_build_world()
	_build_ranat()
	_build_lanes()
	_build_label()
	_build_player()
	_build_audio()
	phrases = _parse(MELODY)
	t0_usec = Time.get_ticks_usec()
	print("เมืองที่สร้างจากเสียง: ", "VR (OpenXR)" if xr_on else "desktop (no headset found)")


func now_s() -> float:
	return (Time.get_ticks_usec() - t0_usec) / 1000000.0


# --------------------------------------------------------------------------------------------------
# World
# --------------------------------------------------------------------------------------------------
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.02, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.4, 0.7)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.66, 0.71, 1.0)
	moon.light_energy = 0.6
	moon.rotation_degrees = Vector3(-55, 30, 0)
	add_child(moon)
	var warm := OmniLight3D.new()
	warm.light_color = Color(1.0, 0.62, 0.3)
	warm.light_energy = 1.2
	warm.omni_range = 3.0
	warm.position = RANAT_POS + Vector3(0, 0.5, 0.3)
	add_child(warm)

	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	floor_mi.mesh = plane
	floor_mi.material_override = _mat(Color(0.03, 0.02, 0.04), 0.9, 0.15)
	add_child(floor_mi)

	# stars on a dome
	var star_mesh := SphereMesh.new()
	star_mesh.radius = 0.12
	star_mesh.height = 0.24
	star_mesh.radial_segments = 6
	star_mesh.rings = 3
	var star_mat := StandardMaterial3D.new()
	star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	star_mat.albedo_color = Color(0.85, 0.87, 1.0)
	star_mesh.material = star_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = star_mesh
	mm.instance_count = 700
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in mm.instance_count:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.05, 1), rng.randf_range(-1, 1)).normalized()
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * rng.randf_range(0.5, 1.5)), d * 80.0))
	var stars := MultiMeshInstance3D.new()
	stars.multimesh = mm
	add_child(stars)

	var title := Label3D.new()
	title.text = "เมืองที่สร้างจากเสียง\nต้นแบบ Godot · บรรเลงตามโน้ต"
	title.font = font
	title.font_size = 96
	title.pixel_size = 0.004
	title.modulate = Color(1.0, 0.86, 0.55)
	title.outline_size = 0
	title.position = Vector3(0, 1.65, -5.0)
	add_child(title)


func _mat(albedo: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	return m


func _glow_mat(c: Color, energy: float, additive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c * energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return m


# --------------------------------------------------------------------------------------------------
# ระนาดเอก
# --------------------------------------------------------------------------------------------------
func _build_ranat() -> void:
	ranat = Node3D.new()
	ranat.position = RANAT_POS
	add_child(ranat)
	var lacquer := _mat(Color(0.42, 0.08, 0.06), 0.38, 0.25)
	var gold := _mat(Color(0.89, 0.69, 0.33), 0.28, 1.0)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 0.12, 0.36)
	body.mesh = bm
	body.material_override = lacquer
	body.position = Vector3(0, -0.07, 0)
	ranat.add_child(body)
	for sx in [-1.0, 1.0]:
		var end := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3(0.1, 0.22, 0.36)
		end.mesh = em
		end.material_override = lacquer
		end.position = Vector3(sx * 0.6, 0.0, 0)
		ranat.add_child(end)
	var foot := MeshInstance3D.new()
	var fm := CylinderMesh.new()
	fm.top_radius = 0.1
	fm.bottom_radius = 0.16
	fm.height = 0.12
	foot.mesh = fm
	foot.material_override = gold
	foot.position = Vector3(0, -0.19, 0)
	ranat.add_child(foot)

	for i in KEYS:
		var k := RanatKey.new()
		k.i = i
		k.x = -0.455 + i * 0.07
		k.length = lerpf(0.34, 0.23, float(i) / (KEYS - 1))
		k.y0 = 0.06 * pow(k.x / 0.5, 2) + 0.012
		k.mesh = MeshInstance3D.new()
		var km := BoxMesh.new()
		km.size = Vector3(0.058, 0.024, k.length)
		k.mesh.mesh = km
		k.mat = _mat(Color.from_hsv(0.06, 0.55, 0.42 + (i % 2) * 0.04), 0.45, 0.05)
		k.mat.emission_enabled = true
		k.mat.emission = KEY_GLOW
		k.mat.emission_energy_multiplier = 0.0
		k.mesh.material_override = k.mat
		k.mesh.position = Vector3(k.x, k.y0, 0)
		ranat.add_child(k.mesh)
		# a collider for desktop clicks and the controller's trigger ray
		var body_k := StaticBody3D.new()
		body_k.set_meta("key", i)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = km.size
		cs.shape = shape
		body_k.add_child(cs)
		k.mesh.add_child(body_k)
		keys.append(k)


# Guitar Hero style lanes: a thin light line in each key's colour runs out from the far side of the ranat,
# rising gently away from the player; guide lights travel down it and land on the key on the beat
func _build_lanes() -> void:
	var tilt := atan2(LANE_RISE, LANE_LEN)
	for k in keys:
		var end := Vector3(k.x, k.y0 + 0.03, 0)
		var start := Vector3(k.x, end.y + LANE_RISE, -LANE_LEN)
		lane_start.append(start)
		lane_end.append(end)
		var line := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.008, 0.002, start.distance_to(end))
		line.mesh = lm
		var m := _glow_mat(GUIDE_COLORS[k.i % 7], 1.0, true)
		line.material_override = m
		line.position = (start + end) * 0.5
		line.rotation.x = tilt
		ranat.add_child(line)
		lane_mats.append(m)


func _build_label() -> void:
	label = Label3D.new()
	label.font = font
	label.font_size = 64
	label.pixel_size = 0.0009
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(1, 0.95, 0.8, 0)
	label.outline_modulate = Color(0.3, 0.15, 0.0, 0)
	label.position = Vector3(-0.85, 0.26, 0.02)  # above the ranat's left end, out of the lanes
	ranat.add_child(label)


# --------------------------------------------------------------------------------------------------
# Player: XR origin with a mallet in each hand, or a desktop camera
# --------------------------------------------------------------------------------------------------
func _build_player() -> void:
	if not xr_on:
		desk_cam = Camera3D.new()
		desk_cam.fov = 70
		add_child(desk_cam)
		desk_cam.position = Vector3(0, 1.45, 0.35)
		desk_cam.look_at(RANAT_POS + Vector3(0, 0.05, -0.1))
		desk_cam.current = true
		return
	var origin := XROrigin3D.new()
	add_child(origin)
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	for tracker in ["left_hand", "right_hand"]:
		var c := XRController3D.new()
		c.tracker = tracker
		c.pose = "grip"
		origin.add_child(c)
		var m := Mallet.new()
		m.ctrl = c
		m.head = _make_mallet(c)
		mallets.append(m)
		c.button_pressed.connect(_on_button.bind(c))


func _make_mallet(parent: Node3D) -> Node3D:
	var g := Node3D.new()
	g.rotation.x = -0.45  # the stick hangs slightly down from the fist
	parent.add_child(g)
	var handle := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0045
	hm.bottom_radius = 0.006
	hm.height = 0.3
	handle.mesh = hm
	handle.material_override = _mat(Color(0.23, 0.13, 0.08), 0.6, 0.0)
	handle.rotation.x = PI / 2
	handle.position.z = 0.04 - 0.15
	g.add_child(handle)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = HEAD_R
	sm.height = HEAD_R * 2
	head.mesh = sm
	head.material_override = _mat(Color(0.42, 0.08, 0.06), 0.38, 0.25)
	head.scale = Vector3(1, 1, 0.75)
	head.position.z = 0.04 - 0.3 - HEAD_R * 0.5
	g.add_child(head)
	return head


# the trigger still strikes the key the controller points at
func _on_button(action: String, c: XRController3D) -> void:
	if action != "trigger_click":
		return
	var from := c.global_position
	var to := from + (-c.global_transform.basis.z) * 3.0
	var i := _ray_key(from, to)
	if i >= 0:
		var hit := strike(i, 1.1)
		c.trigger_haptic_pulse("haptic", 0.0, 1.0 if hit else 0.4, 0.07 if hit else 0.025, 0.0)


func _ray_key(from: Vector3, to: Vector3) -> int:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	if r.is_empty():
		return -1
	var body: Object = r["collider"]
	return int(body.get_meta("key")) if body.has_meta("key") else -1


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and desk_cam:
		var from := desk_cam.project_ray_origin(mb.position)
		var i := _ray_key(from, from + desk_cam.project_ray_normal(mb.position) * 5.0)
		if i >= 0:
			strike(i, 1.1)
		return
	var kb := event as InputEventKey
	if kb and kb.pressed and not kb.echo:
		var i := KEYMAP.find(OS.get_keycode_string(kb.keycode).to_lower())
		if i >= 0:
			strike(i, 1.1)


# --------------------------------------------------------------------------------------------------
# Audio: every sound is synthesised at start-up, like the web version's Web Audio partials
# --------------------------------------------------------------------------------------------------
func key_freq(i: int) -> float:
	return 290.0 * pow(2.0, i / 7.0)  # Thai 7-tone equal temperament


# a sum of decaying sine partials [frequency, amplitude, seconds to fade to 0.1%], plus a short noise click
func _synth(partials: Array, dur: float, gain: float, click := 0.0) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for s in n:
		var t := float(s) / RATE
		var v := 0.0
		for p in partials:
			v += p[1] * exp(-t * 6.9 / p[2]) * sin(TAU * p[0] * t)
		if click > 0.0 and t < 0.03:
			v += click * rng.randf_range(-1, 1) * exp(-t / 0.006)
		v *= gain * minf(1.0, t / 0.002)  # 2 ms attack so notes don't click
		data.encode_s16(s * 2, int(clampf(v, -1, 1) * 32767))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


func _build_audio() -> void:
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.7
	rev.wet = 0.25
	AudioServer.add_bus_effect(0, rev)
	for i in 32:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)
	for i in KEYS:
		var f := key_freq(i)
		note_streams.append(_synth([[f, 1.0, 0.75], [f * 2.01, 0.18, 0.35], [f * 2.76, 0.32, 0.22], [f * 5.4, 0.12, 0.08]], 0.9, 0.32, 0.35))
		chime_streams.append(_synth([[f * 4, 1.0, 0.4]], 0.45, 0.08))
		chime5_streams.append(_synth([[f * 4, 1.0, 0.4], [f * 6, 0.7, 0.5]], 0.55, 0.08))
	gong_stream = _synth([[145.0, 1.0, 2.6], [146.6, 0.6, 2.4], [292.9, 0.25, 1.4], [435.0, 0.08, 0.7]], 2.6, 0.22)
	ching_open = _synth([[2730.0, 1.0, 1.4], [3905.0, 0.5, 1.2], [5190.0, 0.33, 1.0], [6620.0, 0.25, 0.8]], 1.4, 0.06)
	ching_closed = _synth([[2730.0, 0.6, 0.06]], 0.1, 0.06, 0.5)


func play(stream: AudioStream, vel: float) -> void:
	if vel <= 0.001:
		return
	var p := players[next_player]
	next_player = (next_player + 1) % players.size()
	p.stream = stream
	p.volume_db = linear_to_db(vel)
	p.play()


# --------------------------------------------------------------------------------------------------
# Melody, guides and combo
# --------------------------------------------------------------------------------------------------
func _parse(text: String) -> Array:
	var out := []
	for line in text.strip_edges().split("\n"):
		var ph := []
		for tok in line.split(" ", false):
			if tok == "|":
				continue
			if tok == "-":
				ph.append(REST)
			elif tok == "~":
				ph.append(ROLL)
			elif NOTE.has(tok.substr(0, 1)):
				ph.append(NOTE[tok.substr(0, 1)] + (7 if tok.ends_with("'") else 0))
			else:
				push_error("โน้ตไม่ถูกต้อง: " + tok)
		out.append(ph)
	return out


func combo_level() -> float:
	return smoothstep(0.0, 1.0, clampf(combo / 10.0, 0.0, 1.0))


# the teacher plays a missed note softly, and fades further as the player's combo grows
func teacher_level() -> float:
	return lerpf(0.55, 0.2, combo_level())


func _plan_step(t: float) -> void:
	var ph: Array = phrases[phrase_idx]
	var n: int = ph[pos]
	var acc := 1.0 - 0.6 * combo_level()
	if n >= 0:
		last_key = n
		_add_guide(n, t, 1.0)
		if step_i % 2 == 0 and n + 7 < KEYS:
			events.append({"t": t, "kind": "note", "key": n + 7, "vel": 0.5 * acc})
	elif n == ROLL:
		_add_guide(last_key, t, 0.45)  # the roll's first stroke is the player's
		for r in range(1, 4):
			var kk := last_key if r % 2 == 0 else mini(KEYS - 1, last_key + 7)
			events.append({"t": t + r * STEP / 4.0, "kind": "note", "key": kk, "vel": 0.45 * acc})
	if step_i % 2 == 0:
		events.append({"t": t, "kind": "ching", "open": step_i % 4 == 0})
	if step_i % 4 == 0:
		events.append({"t": t, "kind": "gong"})
	step_i += 1
	pos += 1
	if pos >= ph.size():
		pos = 0
		phrase_idx = (phrase_idx + 1) % phrases.size()


func _add_guide(key: int, t: float, vel: float) -> void:
	var g := Guide.new()
	g.key = key
	g.t = t
	g.vel = vel
	g.orb = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.022
	sm.height = 0.044
	g.orb.mesh = sm
	g.mat = _glow_mat(GUIDE_COLORS[key % 7], 1.3, true)  # bright enough to bloom, not so bright it washes to white
	g.orb.material_override = g.mat
	g.orb.visible = false
	ranat.add_child(g.orb)
	guides.append(g)


func _fire(e: Dictionary) -> void:
	match e["kind"]:
		"note":
			play(note_streams[e["key"]], e["vel"])
			keys[e["key"]].flash = maxf(keys[e["key"]].flash, 0.2)
		"ching":
			play(ching_open if e["open"] else ching_closed, 1.0)
		"gong":
			play(gong_stream, 1.0)


# returns true when the strike landed on a guide's beat
func strike(i: int, vel: float) -> bool:
	var g := _judge(i)
	var v := vel
	if g and g.teacher:
		v *= 0.35  # the teacher already played this beat: a light accent, not a second full note
	play(note_streams[i], v * 0.9)
	keys[i].flash = maxf(keys[i].flash, 0.5 + vel * 0.8)
	return g != null


func _judge(i: int) -> Guide:
	var now := now_s()
	var best: Guide = null
	for g in guides:
		if g.state != "" or g.key != i or absf(g.t - now) > HIT_WIN:
			continue
		if best == null or absf(g.t - now) < absf(best.t - now):
			best = g
	if best == null:
		return null
	best.state = "hit"  # struck before the beat: the teacher will skip it
	var perfect := absf(best.t - now) <= PERFECT_WIN
	_set_combo(combo + 1, "ตรงจังหวะ!" if perfect else "ดี")
	keys[i].hit = 1.4 if perfect else 1.0
	play(chime5_streams[i] if perfect else chime_streams[i], 1.0)
	_hit_fx(i, perfect)
	return best


func _set_combo(n: int, word: String) -> void:
	combo = n
	if word != "":
		label_word = word
		label_t = now_s()
	var lines := PackedStringArray()
	if now_s() - label_t < 0.6:
		lines.append(label_word)
	if combo >= 3:
		lines.append("คอมโบ %d" % combo)
	label.text = "\n".join(lines)


# a flat ring in the key's colour spreads across the key top, and a brief white flame rises a few cm
func _hit_fx(i: int, perfect: bool) -> void:
	var k := keys[i]
	var top := ranat.to_global(Vector3(k.x, k.y0 + 0.016, 0))
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.022
	tm.outer_radius = 0.03
	ring.mesh = tm
	var rf := Fx.new()
	rf.mat = _glow_mat(GUIDE_COLORS[i % 7], 1.2, true)
	ring.material_override = rf.mat
	add_child(ring)
	ring.global_position = top
	rf.node = ring
	rf.t0 = now_s()
	rf.dur = 0.3
	rf.grow = 3.6 if perfect else 2.8
	fxs.append(rf)
	var flame := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.05 if perfect else 0.035
	sm.height = sm.radius * 2
	flame.mesh = sm
	var ff := Fx.new()
	ff.mat = _glow_mat(Color(1, 0.96, 0.86), 1.4, true)
	flame.material_override = ff.mat
	add_child(flame)
	flame.global_position = top
	ff.node = flame
	ff.t0 = now_s()
	ff.dur = 0.25
	ff.grow = 0.5
	ff.rise = 0.3
	fxs.append(ff)


# --------------------------------------------------------------------------------------------------
# Frame loop
# --------------------------------------------------------------------------------------------------
func _process(dt: float) -> void:
	var now := now_s()
	while next_t < now + APPROACH + 0.2:
		_plan_step(next_t)
		next_t += STEP
	var keep: Array[Dictionary] = []
	for e in events:
		if e["t"] <= now:
			_fire(e)
		else:
			keep.append(e)
	events = keep

	_update_guides(now)
	_update_mallets(now, dt)
	_update_fx(now, dt)

	for k in keys:
		k.flash *= pow(0.02, dt)
		k.hit *= pow(0.002, dt)
		var c := k.guide + k.hit * 3.0
		k.mat.emission = KEY_GLOW.lerp(GUIDE_COLORS[k.i % 7], c / (c + k.flash + 0.001))
		k.mat.emission_energy_multiplier = k.flash * 0.9 + k.guide * 0.6 + k.hit * 1.8
		k.mesh.position.y = k.y0 - k.flash * 0.008 - k.hit * 0.01
	for i in KEYS:
		var m := lane_mats[i]
		m.albedo_color.a = 0.12 + keys[i].guide * 0.5

	var show := combo >= 3 or now - label_t < 0.6
	if now - label_t >= 0.6 and label_word != "":
		label_word = ""
		_set_combo(combo, "")
	label.modulate.a = move_toward(label.modulate.a, 1.0 if show else 0.0, dt * 8.0)


func _update_guides(now: float) -> void:
	for k in keys:
		k.guide = 0.0
	var keep: Array[Guide] = []
	for g in guides:
		# the teacher plays the beat if the player has not struck it by then
		if g.state == "" and not g.teacher and now >= g.t:
			g.teacher = true
			play(note_streams[g.key], g.vel * teacher_level())
		if g.state == "" and now > g.t + HIT_WIN:
			g.state = "miss"
			g.done_t = now
			if combo > 0:
				_set_combo(0, "")
		var u := 1.0 - (g.t - now) / APPROACH  # 0 at the far end of the lane, 1 on the key, on the beat
		if g.state == "hit":
			g.orb.queue_free()
			continue
		if g.state == "miss":
			var e := (now - g.done_t) / 0.4
			if e >= 1.0:
				g.orb.queue_free()
				continue
			# a missed light keeps travelling past the key and fades to grey
			g.orb.position = lane_start[g.key].lerp(lane_end[g.key], u)
			g.mat.albedo_color = Color(0.33, 0.31, 0.37, 0.5 * (1.0 - e))
			keep.append(g)
			continue
		keep.append(g)
		if u < 0.0:
			continue
		g.orb.visible = true
		g.orb.position = lane_start[g.key].lerp(lane_end[g.key], u)
		g.orb.scale = Vector3.ONE * lerpf(0.6, 1.2, minf(u, 1.0))
		g.mat.albedo_color.a = minf(1.0, u * 5.0)
		keys[g.key].guide = maxf(keys[g.key].guide, minf(u, 1.0))
	guides = keep


# a hit is the bottom of the mallet head crossing a key's top face on the way down, inside its footprint
func _update_mallets(now: float, dt: float) -> void:
	for h in mallets:
		if not h.ctrl.get_is_active():
			h.ready = false
			continue
		var cur := h.head.global_position
		var loc := ranat.to_local(cur)
		if not h.ready:
			h.prev = cur
			h.prev_loc = loc
			h.ready = true
			continue
		var vy := (loc.y - h.prev_loc.y) / maxf(dt, 0.001)
		var speed := cur.distance_to(h.prev) / maxf(dt, 0.001)
		if vy < -MIN_DOWN_SPEED:
			for k in keys:
				var top := k.y0 + 0.012
				if h.prev_loc.y - HEAD_R < top or loc.y - HEAD_R > top:
					continue
				var s := (h.prev_loc.y - HEAD_R - top) / (h.prev_loc.y - loc.y)
				var x := lerpf(h.prev_loc.x, loc.x, s)
				var z := lerpf(h.prev_loc.z, loc.z, s)
				if absf(x - k.x) > 0.029 + HEAD_R * 0.5 or absf(z) > k.length / 2.0:
					continue
				if k.i == h.last_hit and now - h.last_t < 0.08:
					break
				var vel := minf(1.6, 0.45 + speed * 0.32)
				# a strong, longer pulse when the strike lands on a guide's beat, a light tap otherwise
				if strike(k.i, vel):
					h.ctrl.trigger_haptic_pulse("haptic", 0.0, 1.0, 0.07, 0.0)
				else:
					h.ctrl.trigger_haptic_pulse("haptic", 0.0, 0.15 + vel * 0.3, 0.03, 0.0)
				h.last_hit = k.i
				h.last_t = now
				break
		h.prev = cur
		h.prev_loc = loc


func _update_fx(now: float, dt: float) -> void:
	var keep: Array[Fx] = []
	for f in fxs:
		var t := (now - f.t0) / f.dur
		if t >= 1.0:
			f.node.queue_free()
			continue
		f.node.scale = Vector3.ONE * lerpf(1.0, f.grow, 1.0 - pow(1.0 - t, 3.0))
		f.node.position.y += f.rise * dt
		f.mat.albedo_color.a = 1.0 - t * t
		keep.append(f)
	fxs = keep
