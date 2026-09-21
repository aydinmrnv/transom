"""Offline asset build: blender --background --python render_mac_studio.py -- model.usdz output.png"""
import bpy
import sys
from mathutils import Vector

source, output = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=source)
points = [o.matrix_world @ Vector(v) for o in bpy.context.scene.objects if o.type == 'MESH' for v in o.bound_box]
lo = Vector(tuple(min(p[i] for p in points) for i in range(3)))
hi = Vector(tuple(max(p[i] for p in points) for i in range(3)))
center = (lo + hi) * .5
print('Bounds', tuple(lo), tuple(hi))

def aim(obj):
    obj.rotation_euler = (center - obj.location).to_track_quat('-Z', 'Y').to_euler()

bpy.ops.object.camera_add(location=center + Vector((.30, -.58, .31)))
camera = bpy.context.object
camera.data.type = 'ORTHO'
camera.data.ortho_scale = .30
aim(camera)
scene = bpy.context.scene
scene.camera = camera
for name, offset, energy, size in [
    ('Key', (-.25, -.35, .5), 12, .4),
    ('Fill', (.35, -.1, .22), 5, .3),
    ('Rim', (-.1, .3, .35), 8, .25),
]:
    light = bpy.data.lights.new(name, 'AREA')
    light.energy, light.shape, light.size = energy, 'DISK', size
    obj = bpy.data.objects.new(name, light)
    scene.collection.objects.link(obj)
    obj.location = center + Vector(offset)
    aim(obj)
scene.world = bpy.data.worlds.new('Studio')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.65, .70, .8, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .35
scene.render.engine = 'CYCLES'
scene.cycles.samples = 48
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_x, scene.render.resolution_y = 768, 512
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'AgX'
scene.render.filepath = output
bpy.ops.render.render(write_still=True)
