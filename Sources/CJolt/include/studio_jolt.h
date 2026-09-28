// C-linkage wrapper around Jolt Physics, so Swift can drive it without C++ interop.
// One world per play session. Bodies are addressed by the 32-bit id Jolt gives them.
#ifndef STUDIO_JOLT_H
#define STUDIO_JOLT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StudioJoltWorld StudioJoltWorld;

/// An id that is never a real body.
#define STUDIO_JOLT_NO_BODY 0xffffffffu

enum StudioJoltShape {
    STUDIO_JOLT_BOX = 0,       // params: half extents x, y, z
    STUDIO_JOLT_SPHERE = 1,    // params: radius
    STUDIO_JOLT_CYLINDER = 2,  // params: half height (along Y), radius
    STUDIO_JOLT_HULL = 3,      // points: x, y, z per point
    STUDIO_JOLT_CAPSULE = 4    // params: half height of the straight part (along Y), radius
};

enum StudioJoltMotion {
    STUDIO_JOLT_STATIC = 0,
    STUDIO_JOLT_DYNAMIC = 1,
    /// Moved by the game, pushing dynamic bodies but never pushed: the player's character.
    STUDIO_JOLT_KINEMATIC = 2
};

StudioJoltWorld *studio_jolt_create(uint32_t maxBodies);
void studio_jolt_destroy(StudioJoltWorld *world);

void studio_jolt_set_gravity(StudioJoltWorld *world, float y);
/// An invisible floor whose top is at y = 0.
void studio_jolt_set_ground(StudioJoltWorld *world, int enabled);

/// A triangle mesh collided exactly (a MeshPart with Precise collision): `vertices`
/// x, y, z each, `indices` three per triangle, counter-clockwise from outside. Only for
/// static bodies — Jolt can't simulate a moving one. Returns a shape id as
/// studio_jolt_make_shape does.
uint32_t studio_jolt_make_mesh_shape(StudioJoltWorld *world, const float *vertices, int vertexCount,
                                     const uint32_t *indices, int triangleCount);

/// The convex hull of some points, as triangles (three indices into `points` each,
/// counter-clockwise from outside), at most `maxVertices` corners. Writes at most
/// `capacity` triangles to `outIndices`; returns how many there are, or 0 if the
/// points have no volume.
int studio_jolt_convex_hull(const float *points, int pointCount, int maxVertices,
                            uint32_t *outIndices, int capacity);

/// Makes a shape to build a body from; returns its id (valid until the next body is
/// added), or STUDIO_JOLT_NO_BODY if the shape couldn't be made.
uint32_t studio_jolt_make_shape(StudioJoltWorld *world, int shape, const float *params, int paramCount,
                                const float *points, int pointCount);

/// A body from shapes made with studio_jolt_make_shape, each placed in the body's
/// frame (`positions`: x, y, z each; `rotations`: x, y, z, w each). Several shapes
/// make one rigid compound: a welded assembly. Returns the body id.
uint32_t studio_jolt_add_compound(StudioJoltWorld *world, const uint32_t *shapes, const float *positions,
                                  const float *rotations, int count,
                                  const float *position, const float *rotation, int motion,
                                  float mass, float friction, float restitution, int canCollide);

/// Returns the new body's id, or STUDIO_JOLT_NO_BODY if the shape couldn't be made.
/// `position` is x, y, z; `rotation` a quaternion x, y, z, w. `mass` is used for
/// dynamic bodies (inertia follows from the shape). A body that can't collide passes
/// through everything.
uint32_t studio_jolt_add_body(StudioJoltWorld *world, int shape, const float *params, int paramCount,
                              const float *points, int pointCount,
                              const float *position, const float *rotation, int motion,
                              float mass, float friction, float restitution, int canCollide);
void studio_jolt_remove_body(StudioJoltWorld *world, uint32_t body);

void studio_jolt_set_pose(StudioJoltWorld *world, uint32_t body, const float *position, const float *rotation);
void studio_jolt_get_pose(StudioJoltWorld *world, uint32_t body, float *position, float *rotation);
void studio_jolt_set_velocity(StudioJoltWorld *world, uint32_t body, const float *linear);
void studio_jolt_get_velocity(StudioJoltWorld *world, uint32_t body, float *linear);
void studio_jolt_set_angular_velocity(StudioJoltWorld *world, uint32_t body, const float *angular);
void studio_jolt_get_angular_velocity(StudioJoltWorld *world, uint32_t body, float *angular);
void studio_jolt_add_impulse(StudioJoltWorld *world, uint32_t body, const float *impulse);
void studio_jolt_add_angular_impulse(StudioJoltWorld *world, uint32_t body, const float *impulse);
void studio_jolt_set_collides(StudioJoltWorld *world, uint32_t body, int canCollide);
void studio_jolt_wake(StudioJoltWorld *world, uint32_t body);
/// Moves a kinematic body to a pose over `dt`, so it has the velocity to push with.
void studio_jolt_move_kinematic(StudioJoltWorld *world, uint32_t body, const float *position,
                                const float *rotation, float dt);
int studio_jolt_is_awake(StudioJoltWorld *world, uint32_t body);
float studio_jolt_mass(StudioJoltWorld *world, uint32_t body);

/// Advances the world by `dt` seconds, split into `collisionSteps` collision steps.
void studio_jolt_step(StudioJoltWorld *world, float dt, int collisionSteps);

/// The awake dynamic bodies, up to `capacity`; returns how many there are.
int studio_jolt_awake_bodies(StudioJoltWorld *world, uint32_t *out, int capacity);

/// Pairs of bodies that started (1) or stopped (0) touching since the last call: five
/// numbers per pair — body a, which of its shapes, body b, which of its shapes,
/// started. Returns the number of pairs. Contacts with the ground are not reported.
int studio_jolt_drain_contacts(StudioJoltWorld *world, uint32_t *out, int capacity);

enum StudioJoltJoint {
    STUDIO_JOLT_HINGE = 1,     // values: limits on (0/1), lower, upper (radians)
    STUDIO_JOLT_POINT = 2,     // ball and socket
    STUDIO_JOLT_ROPE = 3,      // values: length
    STUDIO_JOLT_SPRING = 4,    // values: free length, stiffness, damping
    STUDIO_JOLT_SLIDER = 5,    // values: limits on (0/1), lower, upper (studs)
    STUDIO_JOLT_MOTOR = 6      // held at a pose (studio_jolt_drive_motor): axis and normal are its X and Y
};

/// Joins two bodies. Points, axes and normals are in world space; each body's is
/// given, so the two ends may start apart. With `noCollide` the two bodies stop
/// colliding with each other. Returns a joint id.
uint32_t studio_jolt_add_joint(StudioJoltWorld *world, int kind, uint32_t bodyA, uint32_t bodyB,
                               const float *pointA, const float *pointB,
                               const float *axisA, const float *axisB,
                               const float *normalA, const float *normalB,
                               const float *values, int valueCount, int noCollide);
void studio_jolt_remove_joint(StudioJoltWorld *world, uint32_t joint);
/// Two bodies that pass through each other (a NoCollisionConstraint): counted, so `on` 0
/// undoes one `on` 1, and a joint's own no-colliding is kept apart from it.
void studio_jolt_ignore_pair(StudioJoltWorld *world, uint32_t bodyA, uint32_t bodyB, int on);
/// Drives a hinge (rad/s, torque) or slider (studs/s, force) at a speed, or stops
/// driving it when `on` is 0.
void studio_jolt_drive_joint(StudioJoltWorld *world, uint32_t joint, int on, float speed, float limit);
/// A hinge's angle (radians) or a slider's position (studs).
float studio_jolt_joint_value(StudioJoltWorld *world, uint32_t joint);
/// Where a motor joint holds body B's frame, in body A's frame: a position and a rotation
/// (x, y, z, w). Stiff springs get it there.
void studio_jolt_drive_motor(StudioJoltWorld *world, uint32_t joint, const float *position, const float *rotation);
/// Water's lift and drag on a body for the next step: the water's surface is flat at
/// `surface` (y), and `buoyancy` is the water's density over the body's (above 1 floats).
/// Besides Jolt's drag (which grows with the square of speed), the water takes
/// `settle` of the body's up-and-down speed a second, `slow` of its sideways speed and
/// `spin` of its turning, as much of it as is under. Returns the share under water.
float studio_jolt_float(StudioJoltWorld *world, uint32_t body, float surface, float buoyancy,
                        float linearDrag, float angularDrag, float settle, float slow, float spin, float dt);
/// A dynamic body's inertia (in the world, as it's turned now) times a vector: the
/// angular impulse that changes its spin by `spin`. Zero for a body that doesn't move.
void studio_jolt_inertia_times(StudioJoltWorld *world, uint32_t body, const float *spin, float *out);

#ifdef __cplusplus
}
#endif

#endif
