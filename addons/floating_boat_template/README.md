# Floating Boat Template

The development boat: `floating_boat.tscn` inherits `boat_template`'s
`boat.tscn` and adds a `Weapons` node (`ProjectileWeaponController`: aim,
fire, body recoil). It is not part of the open-source addons; the demo's
boats (`demo/rowboat.tscn` with a bow swivel gun, `demo/floating_box.tscn`
with four cannons) inherit it. Everything else is documented in
`addons/boat_template/README.md`.

`Weapons` sits at child index 4, between `Hitboxes` and `HullWaterFootprint`,
where it was before the template was split; the demo scenes' `index`
attributes depend on that order.

Arming a boat: instance `projectile_launcher.tscn` anywhere under it (e.g. at
each gun). `Weapons` collects every launcher under the body, and aims and fires
only while the boat's `player_controlled` is set. Set each launcher's
`yaw_target_path` to the node that should turn (e.g. `..` for the gun), and add
optional `CannonSlideRecoil` nodes as the launcher's `recoil_receiver_paths`.

Enabling the plugin adds the `fire_projectile` input action (Space) unless the
project has it; enable Boat Template for the drive actions.

Depends on `boat_template` and `projectile_launcher_system`.
