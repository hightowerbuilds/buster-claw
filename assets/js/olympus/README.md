# Olympus environment

Open `/olympus` in the running Phoenix app. This is the environment foundation;
gods and their interactions are a later addition.

- Drag or use arrow keys to orbit. Scroll or use `+` / `-` to zoom.
- Cloud cover changes the density of the moving cloud volume.
- Signal noise changes the strength of the mountain's television static.
- Pause freezes clouds, static, and automatic orbit; manual exploration still works.
- Reduced-motion preferences start the scene paused.

`shaders.js` contains the procedural height field, surface material, sky, and
lit volumetric cloud integration. Terrain depth limits cloud integration so
the cloud layer occludes the slopes correctly from every camera angle.

`scene.js` owns the WebGL resources, animation clock, camera, input, and adaptive
resolution. Its disposer is called by the Olympus LiveView hook on navigation.
The scene requires WebGL 2 and uses no external image assets or new dependencies.
