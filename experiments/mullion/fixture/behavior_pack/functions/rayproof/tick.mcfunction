execute as @a[tag=!rayproof_started] run function rayproof/bootstrap
scoreboard players add @a[tag=!rayproof_ready] rayproof_boot 1
execute as @a[tag=!rayproof_ready,scores={rayproof_boot=60..}] at @s run function rayproof/room
tag @a[tag=!rayproof_ready,scores={rayproof_boot=60..}] add rayproof_ready
execute as @a[tag=rayproof_soak] at @s run function rayproof/soak_tick
