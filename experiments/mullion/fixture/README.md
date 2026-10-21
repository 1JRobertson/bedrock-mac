# Mullion ray-tracing test room

Tiny original test assets, no external textures or scripts. **Verified in Minecraft
Ray Traced mode on the isolated Mullion runtime.** See ../RESULTS.md for evidence.
Build with `python3 build_fixture.py`. This only writes `fixture/out/`: separate
resource/behavior pack folders and `Mullion-RayProof.mcaddon`. It never installs
anything. Stage those two folders only in the experimental prefix's resource and
behavior pack directories, or import the archive through the experimental game.

Create a new empty **Creative / Flat** test world, cheats on, multiplayer off.
Activate **Mullion Ray Proof Room** and **Mullion Ray Proof Materials**. Enable
Minecraft's **Ray Tracing** rendering mode when available. Use 8 chunks and a low
resolution for the first trial. Do not use any existing world.

The fixture now auto-teleports a new test player and builds the room after
60 game ticks. This bootstrap is confined to worlds with this test behavior
pack. If manual setup is needed, use chat:

```text
/tp @s 0.5 101 7.5
/function rayproof/room
```

The first teleport loads the test area. The function replaces the small volume
`x=-7..7, y=100..108, z=0..14`, seals it against sky light, and faces the player
north toward an iron mirror. The white quartz floor receives indirect light.
Behind the player, redstone blocks form a red L; lapis blocks form a blue bar.
Those vanilla blocks have no ordinary block-light emission; their test texture
sets supply PBR emission. The pack gives iron full metalness and zero roughness.

Capture the view without turning around. Run these, waiting a few seconds for
the temporal renderer to settle after each command:

```text
/function rayproof/off
/function rayproof/on
/function rayproof/view
```

`off` replaces only the rear emitters with black concrete; `on` restores them;
`view` returns to the exact camera. Compare matched captures with emitters on/off
and with Ray Tracing disabled/enabled. A stable red L and blue bar visible **in
the mirror while their real blocks remain behind the camera**, plus colored
indirect floor light that responds to emitter removal, is useful visual evidence.
Capture a rear-facing control image to establish what the source pattern is.

Pack activation, shiny blocks, emissive glow, the capability query, and the UI
toggle alone do **not** prove DXR. `raytraced` packs can also be consumed by
Vibrant Visuals. Record the active graphics mode and pair the visual result with
evidence that Minecraft submitted ray dispatches/acceleration-structure work.
The independent DXR probe establishes the translator's rendering capability;
it does not establish that Minecraft used that path.

Material definitions follow Microsoft's [texture-set schema](https://learn.microsoft.com/en-us/minecraft/creator/reference/content/texturesetsreference/texturesetsconcepts/texturesetsintroduction?view=minecraft-bedrock-stable)
and [PBR mirror/capability example](https://github.com/MicrosoftDocs/minecraft-creator/blob/main/creator/Documents/VibrantVisuals/PBROverview.md).
MER channels are metalness, emission, roughness. The pack uses `raytraced` and
three-channel MER rather than the Vibrant Visuals-only subsurface extension.
Functions follow the documented [behavior-pack functions workflow](https://learn.microsoft.com/en-ca/minecraft/creator/documents/functionsintroduction?view=minecraft-bedrock-stable).
