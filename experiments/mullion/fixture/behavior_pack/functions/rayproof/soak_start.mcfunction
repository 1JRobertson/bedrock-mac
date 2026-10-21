scoreboard objectives add rp_soak dummy
scoreboard objectives add rp_phase dummy
scoreboard players set #period rp_phase 3600
scoreboard players set @s rp_soak 0
scoreboard players set @s rp_phase 0
tag @s add rayproof_soak
function rayproof/on
function rayproof/view
tellraw @s {"rawtext":[{"text":"RT soak started: 72000 active game ticks. Camera, emitters and two remote flat-world areas cycle automatically. /function rayproof/soak_stop stops it."}]}
