@tool
class_name AtmosphereNode
extends MeshInstance3D

# Exports
@export var camera_path: NodePath;

@export var sun_direction = Vector3(0, 0, 1):
	set(new_value):
		sun_direction = new_value
		reset_shader()

# EARTH
@export var planet_radius = 6370.0:
	set(new_value):
		planet_radius = new_value
		reset_shader()
@export var atmosphere_height = 80.0:
	set(new_value):
		atmosphere_height = new_value
		reset_shader()
@export_custom(PROPERTY_HINT_RANGE, "0,1,0.000001,or_greater,or_less") var rayleigh_scattering: Vector3 = Vector3(0.0058, 0.0135, 0.0331):
	set(new_value):
		rayleigh_scattering = new_value
		reset_shader()
@export var rayleigh_scale_height: float = 8.0:
	set(new_value):
		rayleigh_scale_height = new_value
		reset_shader()
@export_custom(PROPERTY_HINT_RANGE, "0,1,0.000001,or_greater,or_less") var mie_scattering: Vector3 = Vector3(0.004, 0.004, 0.004):
	set(new_value):
		mie_scattering = new_value
		reset_shader()
@export var mie_scale_height: float = 1.2:
	set(new_value):
		mie_scale_height = new_value
		reset_shader()

# MARS (leaving it here for now for easier access)
# @export var planet_radius = 6370.0;
# @export var atmosphere_height = 80.0;
# @export_custom(PROPERTY_HINT_RANGE, "0,1,0.000001,or_greater,or_less") var rayleigh_scattering: Vector3 = Vector3(19.918, 13.57, 5.75) * (6370 / 3396);
# @export var rayleigh_scale_height: float = 1.0 * (6370 / 3396);
# @export_custom(PROPERTY_HINT_RANGE, "0,1,0.000001,or_greater,or_less") var mie_scattering: Vector3 = Vector3(0.004, 0.004, 0.004) * (6370 / 3396);
# @export var mie_scale_height: float = 0.2 * (6370 / 3396);

# Variables
var atmosphere_post_process_plane: MeshInstance3D
var atmos_shader_mat: ShaderMaterial;
var _camera: Camera3D
var camera: Camera3D:
	set(new_value):
		_camera = new_value
	get:
		if Engine.is_editor_hint():
			return EditorInterface.get_editor_viewport_3d().get_camera_3d()
		else:
			return _camera

# Lookup texture2d configuration
var transmittance_lut_width = 256 # 256
var transmittance_lut_height = 64 # 64
var sky_view_lut_width = 256
var sky_view_lut_height = 100
var aerial_perspective_lut_width = 32
var aerial_perspective_lut_height = 32
var aerial_perspective_lut_depth = 32


# Shader related variables
var rendering_device: RenderingDevice
var transmittance_lut_compute_shader: ComputeShaderData
var sky_view_lut_compute_shader: ComputeShaderData
var aerial_perspective_compute_shader: ComputeShaderData
var shader_loaded = false
var cached_transform: Transform3D

func _ready() -> void:
	if camera_path == null or !has_node(camera_path):
		printerr("Atmosphere needs a valid camera reference to render to!")
		return

	# Get the camera ASAP, we need it for LUT calculations
	camera = get_node(camera_path) as Camera3D

	cached_transform = global_transform

func _exit_tree() -> void:
	if not shader_loaded:
		return
	atmosphere_post_process_plane.queue_free()
	RenderingServer.call_on_render_thread(_free_compute_resources)

func load_shader():
	# Set variables for the shader
	var shader = Shader.new()
	reload_shader(shader)
	var mesh = QuadMesh.new()
	mesh.size = Vector2(2, 2)
	mesh.flip_faces = true

	atmosphere_post_process_plane = MeshInstance3D.new()
	atmosphere_post_process_plane.name = "AtmospherePostProcessPlane"
	atmosphere_post_process_plane.mesh = mesh
	atmosphere_post_process_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	atmosphere_post_process_plane.extra_cull_margin = 999999999999999.0
	atmosphere_post_process_plane.ignore_occlusion_culling = true
	atmosphere_post_process_plane.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	atmosphere_post_process_plane.sorting_offset = -999999999999999.0
	atmosphere_post_process_plane.material_overlay = ShaderMaterial.new()

	camera.add_child(atmosphere_post_process_plane)
	atmosphere_post_process_plane.position = Vector3(0, 0, -2)

	atmos_shader_mat = atmosphere_post_process_plane.material_overlay as ShaderMaterial
	atmos_shader_mat.shader = shader
	set_shader_uniforms(atmos_shader_mat)

	RenderingServer.call_on_render_thread(_initialize_compute_resources)

func _process(_dt: float) -> void:
	if camera == null or not is_inside_tree():
		return
	if not shader_loaded:
		load_shader()
	if cached_transform != global_transform:
		cached_transform = global_transform
		reset_shader()
		return
	handle_shader_reload() # Rendering shader reloading. Can be first, shouldn't matter much where it is.

	# No need to process transmittance every frame - it should only be modified when some properties of the planet change...
	# We do need to process sky_view and aerial_perspective, though!
	if sky_view_lut_compute_shader:
		sky_view_lut_compute_shader.process()
	if aerial_perspective_compute_shader:
		aerial_perspective_compute_shader.process()
	RenderingServer.call_on_render_thread(_render_process)

func read_text_file(path: String):
	var file = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text()

func reload_shader(shader: Shader):
	var source_code = read_text_file(ComputeShaderData.shader_file_path)
	source_code = source_code.replace("#include common.glsl", read_text_file(ComputeShaderData.shading_include_shader_file_path))
	source_code = source_code.replace("#include shading.glsl", read_text_file(ComputeShaderData.shading_include_shader_file_path))
	shader.code = source_code

var last_modified_time
var last_modified_time_2
func handle_shader_reload():
	var new_last_modified_time = FileAccess.get_modified_time(ComputeShaderData.shader_file_path)
	var new_last_modified_time_2 = FileAccess.get_modified_time(ComputeShaderData.shading_include_shader_file_path)
	if new_last_modified_time != last_modified_time || last_modified_time_2 != new_last_modified_time_2:
		last_modified_time = new_last_modified_time
		last_modified_time_2 = new_last_modified_time_2
		reload_shader(atmos_shader_mat.shader)

func create_atmospheric_config() -> PrecomputedAtmosphereConfiguration:
	var config = PrecomputedAtmosphereConfiguration.new()
	config.planet_radius = planet_radius
	config.atmosphere_height = atmosphere_height

	config.rayleigh_scattering = rayleigh_scattering
	config.rayleigh_scale_height = rayleigh_scale_height

	config.mie_scattering = mie_scattering
	config.mie_scale_height = mie_scale_height

	return config

func set_shader_uniforms(atmos_shader_mat: ShaderMaterial):
	atmos_shader_mat.set_shader_parameter("param_planet_position", global_position)
	atmos_shader_mat.set_shader_parameter("param_rayleigh_scattering", rayleigh_scattering)
	atmos_shader_mat.set_shader_parameter("param_rayleigh_scale_height", rayleigh_scale_height)
	atmos_shader_mat.set_shader_parameter("param_mie_scattering", mie_scattering)
	atmos_shader_mat.set_shader_parameter("param_mie_scale_height", mie_scale_height)
	atmos_shader_mat.set_shader_parameter("param_planet_radius", planet_radius)
	atmos_shader_mat.set_shader_parameter("param_atmosphere_height", atmosphere_height)
	atmos_shader_mat.set_shader_parameter("param_sun_direction", sun_direction.normalized())


###############################################
### THE CURSED GODOT COMPUTE SHADER SECTION ###
###############################################

func _render_process() -> void:
	if rendering_device == null:
		printerr('Rendering device on an atmosphere node is null!')
		return
	sky_view_lut_compute_shader.render_process(
		rendering_device,
		(camera.global_position - global_position).length() - planet_radius, # Camera sky_view_lut_height
		sun_direction.normalized().dot((camera.global_position - global_position).normalized()),
		sky_view_lut_width, sky_view_lut_height, 1
	)
	aerial_perspective_compute_shader.render_process(
		rendering_device,
		(camera.global_position - global_position).length() - planet_radius, # Camera sky_view_lut_height
		sun_direction.normalized().dot((camera.global_position - global_position).normalized()),
		aerial_perspective_lut_width, aerial_perspective_lut_height, aerial_perspective_lut_depth
	)


func _free_compute_resources() -> void:
	sky_view_lut_compute_shader.clear_rids(rendering_device)
	aerial_perspective_compute_shader.clear_rids(rendering_device)
	transmittance_lut_compute_shader.clear_rids(rendering_device)
	rendering_device = null
	shader_loaded = false

func _initialize_compute_resources() -> void:
	rendering_device = RenderingServer.get_rendering_device()

	var config = create_atmospheric_config()
	# Create and set LUTs
	transmittance_lut_compute_shader = ComputeShaderData.new()
	transmittance_lut_compute_shader.create_compute_shader_uniforms(
		rendering_device,
		config,
		ComputeShaderData.transmittance_lut_shader_file_path,
		transmittance_lut_width, transmittance_lut_height, 1
	)
	# Run the transmittance shader ONCE - this is important, it's NOT redrawn every frame...
	transmittance_lut_compute_shader.render_process(
		rendering_device,
		(camera.global_position - global_position).length() - planet_radius, # Camera sky_view_lut_height
		sun_direction.normalized().dot((camera.global_position - global_position).normalized()),
		transmittance_lut_width, transmittance_lut_height, 1
	)
	atmos_shader_mat.set_shader_parameter("param_transmittance_lut", transmittance_lut_compute_shader.output_texture_rd)

	sky_view_lut_compute_shader = ComputeShaderData.new()
	sky_view_lut_compute_shader.create_compute_shader_uniforms(
		rendering_device,
		config,
		ComputeShaderData.sky_view_lut_shader_file_path,
		sky_view_lut_width, sky_view_lut_height, 1,
		transmittance_lut_compute_shader.output_texture
	)
	atmos_shader_mat.set_shader_parameter("param_sky_view_lut", sky_view_lut_compute_shader.output_texture_rd)

	aerial_perspective_compute_shader = ComputeShaderData.new()
	aerial_perspective_compute_shader.create_compute_shader_uniforms(
		rendering_device,
		config,
		ComputeShaderData.aerial_perspective_lut_shader_file_path,
		aerial_perspective_lut_width, aerial_perspective_lut_height, aerial_perspective_lut_depth,
		transmittance_lut_compute_shader.output_texture
	)
	atmos_shader_mat.set_shader_parameter("param_aerial_perspective_lut", aerial_perspective_compute_shader.output_texture_rd)

	shader_loaded = true

# This function is called whenever shader properties change and we need to run everything from scratch again...
func reset_shader():
	if not shader_loaded or !is_inside_tree():
		return
	_exit_tree()
