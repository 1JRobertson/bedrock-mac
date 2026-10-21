# Replaces only the test volume x=-7..7, y=100..108, z=0..14.
gamerule dodaylightcycle false
gamerule doweathercycle false
gamerule domobspawning false
time set noon
weather clear
fill -7 100 0 7 108 14 minecraft:black_concrete
fill -6 101 1 6 107 13 minecraft:air
fill -6 100 1 6 100 13 minecraft:quartz_block
fill -5 101 0 5 106 0 minecraft:iron_block
function rayproof/on
function rayproof/view
tellraw @s {"rawtext":[{"text":"Ray proof room ready. Rear red/blue emitters are behind the camera; look for their mirror image. /function rayproof/off and /function rayproof/on control them."}]}
