If you want to read the code to learn how the shader works, keep the following in mind:
- we first precompute a transmittance lut (once, before drawing the atmosphere), see `transmittance.txt`
- every frame, we compute a skyview and aerial perspective luts, see `sky_view.txt`, and `aerial_perspective.txt`
- the shader is actually outputting pixels to the screen is in `atmosphere.txt` and uses the luts for faster calculations
