# One hour at 20 simulation ticks/second. Paused time does not advance the count.
scoreboard players add @s rp_soak 1
scoreboard players operation @s rp_phase = @s rp_soak
scoreboard players operation @s rp_phase %= #period rp_phase
execute if score @s rp_phase matches 1 run function rayproof/on
execute if score @s rp_phase matches 1 run function rayproof/view
execute if score @s rp_phase matches 400 run function rayproof/off
execute if score @s rp_phase matches 600 run function rayproof/on
execute if score @s rp_phase matches 1000 run tp @s 0.5 101 7.5 0 0
execute if score @s rp_phase matches 1400 run tp @s 0.5 101 7.5 90 0
execute if score @s rp_phase matches 1800 run tp @s 512.5 4 512.5 45 30
execute if score @s rp_phase matches 2200 run tp @s -512.5 4 -512.5 -135 30
execute if score @s rp_phase matches 2600 run function rayproof/view
execute if score @s rp_phase matches 3000 run function rayproof/off
execute if score @s rp_phase matches 3200 run function rayproof/on
titleraw @s actionbar {"rawtext":[{"text":"RT SOAK active ticks: "},{"score":{"name":"@s","objective":"rp_soak"}},{"text":" / 72000"}]}
execute if score @s rp_soak matches 72000.. run function rayproof/soak_complete
