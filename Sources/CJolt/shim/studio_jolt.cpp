// C-linkage wrapper around Jolt Physics for the Studio. See include/studio_jolt.h.

#include <Jolt/Jolt.h>

#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Geometry/ConvexHullBuilder.h>
#include <Jolt/Physics/Collision/GroupFilter.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Constraints/SliderConstraint.h>
#include <Jolt/Physics/Constraints/SixDOFConstraint.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyLock.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "../include/studio_jolt.h"

JPH_SUPPRESS_WARNINGS

using namespace JPH;

namespace {

// Object layers: what can collide with what.
namespace Layers {
    constexpr ObjectLayer Static = 0;   // anchored parts and the floor
    constexpr ObjectLayer Moving = 1;   // unanchored parts
    constexpr ObjectLayer Ghost = 2;    // CanCollide off: falls, but passes through everything
    constexpr ObjectLayer Character = 3; // the player: meets only unanchored parts
    constexpr ObjectLayer Count = 4;
}

namespace BroadPhaseLayers {
    constexpr BroadPhaseLayer Static(0);
    constexpr BroadPhaseLayer Moving(1);
    constexpr uint Count = 2;
}

class BroadPhaseLayerMap final : public BroadPhaseLayerInterface {
public:
    uint GetNumBroadPhaseLayers() const override { return BroadPhaseLayers::Count; }
    BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer layer) const override {
        return layer == Layers::Static ? BroadPhaseLayers::Static : BroadPhaseLayers::Moving;
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char *GetBroadPhaseLayerName(BroadPhaseLayer layer) const override {
        return layer == BroadPhaseLayers::Static ? "Static" : "Moving";
    }
#endif
};

class ObjectVsBroadPhase final : public ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(ObjectLayer layer, BroadPhaseLayer broadPhase) const override {
        switch (layer) {
        case Layers::Static: return broadPhase == BroadPhaseLayers::Moving;
        case Layers::Moving: return true;
        // Jolt checks a pair of awake bodies from one side only — whichever woke first —
        // so the player's capsule has to look for parts too, or a part dropped on a
        // player who is up and moving passes straight through.
        case Layers::Character: return broadPhase == BroadPhaseLayers::Moving;
        default: return false;
        }
    }
};

class ObjectPairs final : public ObjectLayerPairFilter {
public:
    bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override {
        if (a == Layers::Ghost || b == Layers::Ghost) return false;
        if (a == Layers::Character || b == Layers::Character) {
            return a == Layers::Moving || b == Layers::Moving;
        }
        return !(a == Layers::Static && b == Layers::Static);
    }
};

// Collects bodies that start and stop touching, for Touched and TouchEnded.
class ContactCollector final : public ContactListener {
public:
    BodyID ground;

    void OnContactAdded(const Body &a, const Body &b, const ContactManifold &manifold, ContactSettings &) override {
        record(a.GetID(), manifold.mSubShapeID1, b.GetID(), manifold.mSubShapeID2, 1);
    }

    void OnContactRemoved(const SubShapeIDPair &pair) override {
        record(pair.GetBody1ID(), pair.GetSubShapeID1(), pair.GetBody2ID(), pair.GetSubShapeID2(), 0);
    }

    std::vector<uint32_t> drain() {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<uint32_t> out;
        out.swap(events);
        return out;
    }

private:
    std::mutex mutex;
    std::vector<uint32_t> events;

    void record(BodyID a, SubShapeID subA, BodyID b, SubShapeID subB, uint32_t started) {
        if (a == ground || b == ground) return;
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back(a.GetIndexAndSequenceNumber());
        events.push_back(subA.GetValue());
        events.push_back(b.GetIndexAndSequenceNumber());
        events.push_back(subB.GetValue());
        events.push_back(started);
    }
};

// Bodies joined by a hinge, ball socket or slider don't collide with each other.
class JointFilter final : public GroupFilter {
public:
    std::unordered_map<uint64_t, int> pairs;

    static uint64_t key(uint32_t a, uint32_t b) {
        if (a > b) std::swap(a, b);
        return (uint64_t(a) << 32) | b;
    }

    bool CanCollide(const CollisionGroup &a, const CollisionGroup &b) const override {
        return pairs.find(key(a.GetSubGroupID(), b.GetSubGroupID())) == pairs.end();
    }
};

struct Joint {
    Ref<TwoBodyConstraint> constraint;
    int kind;
    uint32_t a, b;
    bool noCollide;
};

void ensureRegistered() {
    static std::once_flag once;
    std::call_once(once, [] {
        RegisterDefaultAllocator();
        Factory::sInstance = new Factory();
        RegisterTypes();
    });
}

Vec3 vec(const float *v) { return Vec3(v[0], v[1], v[2]); }
void store(Vec3 v, float *out) { out[0] = v.GetX(); out[1] = v.GetY(); out[2] = v.GetZ(); }

} // namespace

struct StudioJoltWorld {
    PhysicsSystem system;
    TempAllocatorImpl temp { 16 * 1024 * 1024 };
    JobSystemSingleThreaded jobs { cMaxPhysicsJobs };
    BroadPhaseLayerMap broadPhaseLayers;
    ObjectVsBroadPhase objectVsBroadPhase;
    ObjectPairs objectPairs;
    ContactCollector contacts;
    BodyID ground;
    Ref<JointFilter> jointFilter = new JointFilter();
    std::vector<RefConst<Shape>> pendingShapes;
    std::unordered_map<uint32_t, Joint> joints;
    uint32_t nextJoint = 1;

    BodyInterface &bodies() { return system.GetBodyInterface(); }
};

namespace {
void removeJointsOf(StudioJoltWorld *world, uint32_t body);
}

extern "C" {

StudioJoltWorld *studio_jolt_create(uint32_t maxBodies) {
    ensureRegistered();
    auto *world = new StudioJoltWorld();
    world->system.Init(std::max<uint32_t>(maxBodies, 64), 0, 65536, 20480,
                       world->broadPhaseLayers, world->objectVsBroadPhase, world->objectPairs);
    world->system.SetContactListener(&world->contacts);

    // Jolt is tuned for metres; a stud is about 0.28 m and Roblox gravity is 196.2
    // studs/s², so distances scale up a few times.
    PhysicsSettings settings = world->system.GetPhysicsSettings();
    settings.mSpeculativeContactDistance = 0.08f;
    settings.mPenetrationSlop = 0.03f;
    settings.mMaxPenetrationDistance = 0.8f;
    settings.mPointVelocitySleepThreshold = 0.15f;
    settings.mTimeBeforeSleep = 0.5f;
    settings.mNumVelocitySteps = 12;
    settings.mNumPositionSteps = 3;
    world->system.SetPhysicsSettings(settings);
    world->system.SetGravity(Vec3(0, -196.2f, 0));
    return world;
}

void studio_jolt_destroy(StudioJoltWorld *world) {
    if (!world) return;
    BodyIDVector all;
    world->system.GetBodies(all);
    if (!all.empty()) {
        world->bodies().RemoveBodies(all.data(), (int)all.size());
        world->bodies().DestroyBodies(all.data(), (int)all.size());
    }
    delete world;
}

void studio_jolt_set_gravity(StudioJoltWorld *world, float y) {
    world->system.SetGravity(Vec3(0, y, 0));
}

void studio_jolt_set_ground(StudioJoltWorld *world, int enabled) {
    BodyInterface &bodies = world->bodies();
    if (enabled && world->ground.IsInvalid()) {
        BodyCreationSettings settings(new BoxShape(Vec3(10000, 1, 10000)), RVec3(0, -1, 0), Quat::sIdentity(),
                                      EMotionType::Static, Layers::Static);
        settings.mFriction = 0.5f;
        settings.mRestitution = 0.2f;
        world->ground = bodies.CreateAndAddBody(settings, EActivation::DontActivate);
        world->contacts.ground = world->ground;
    } else if (!enabled && !world->ground.IsInvalid()) {
        bodies.RemoveBody(world->ground);
        bodies.DestroyBody(world->ground);
        world->ground = BodyID();
        world->contacts.ground = BodyID();
    }
}

uint32_t studio_jolt_make_mesh_shape(StudioJoltWorld *world, const float *vertices, int vertexCount,
                                     const uint32_t *indices, int triangleCount) {
    if (vertexCount < 3 || triangleCount < 1) return STUDIO_JOLT_NO_BODY;
    VertexList points;
    points.reserve(vertexCount);
    for (int i = 0; i < vertexCount; i++) points.push_back(Float3(vertices[i * 3], vertices[i * 3 + 1], vertices[i * 3 + 2]));
    IndexedTriangleList triangles;
    triangles.reserve(triangleCount);
    for (int i = 0; i < triangleCount; i++) {
        uint32_t a = indices[i * 3], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        if (a >= (uint32_t)vertexCount || b >= (uint32_t)vertexCount || c >= (uint32_t)vertexCount) continue;
        triangles.push_back(IndexedTriangle(a, b, c));
    }
    if (triangles.empty()) return STUDIO_JOLT_NO_BODY;
    MeshShapeSettings settings(std::move(points), std::move(triangles));
    ShapeSettings::ShapeResult result = settings.Create();
    if (result.HasError()) return STUDIO_JOLT_NO_BODY;
    world->pendingShapes.push_back(result.Get());
    return (uint32_t)(world->pendingShapes.size() - 1);
}

int studio_jolt_convex_hull(const float *points, int pointCount, int maxVertices,
                            uint32_t *outIndices, int capacity) {
    ensureRegistered();
    if (pointCount < 4) return 0;
    ConvexHullBuilder::Positions positions;
    positions.reserve(pointCount);
    for (int i = 0; i < pointCount; i++) positions.push_back(Vec3(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]));
    ConvexHullBuilder builder(positions);
    const char *error = nullptr;
    ConvexHullBuilder::EResult result = builder.Initialize(std::max(maxVertices, 4), 1.0e-4f, error);
    if (result != ConvexHullBuilder::EResult::Success && result != ConvexHullBuilder::EResult::MaxVerticesReached) return 0;
    // Each face is a polygon: a fan of triangles from its first corner.
    int count = 0;
    for (const ConvexHullBuilder::Face *face : builder.GetFaces()) {
        if (face->mRemoved || face->mFirstEdge == nullptr) continue;
        const ConvexHullBuilder::Edge *first = face->mFirstEdge;
        const ConvexHullBuilder::Edge *edge = first->mNextEdge;
        while (edge != nullptr && edge->mNextEdge != first) {
            if (count < capacity) {
                outIndices[count * 3] = (uint32_t)first->mStartIdx;
                outIndices[count * 3 + 1] = (uint32_t)edge->mStartIdx;
                outIndices[count * 3 + 2] = (uint32_t)edge->mNextEdge->mStartIdx;
            }
            count++;
            edge = edge->mNextEdge;
        }
    }
    return count;
}

uint32_t studio_jolt_make_shape(StudioJoltWorld *world, int shapeKind, const float *params, int paramCount,
                                const float *points, int pointCount) {
    RefConst<Shape> shape;
    switch (shapeKind) {
    case STUDIO_JOLT_BOX: {
        if (paramCount < 3) return STUDIO_JOLT_NO_BODY;
        Vec3 half(std::max(params[0], 0.01f), std::max(params[1], 0.01f), std::max(params[2], 0.01f));
        float radius = std::min(0.05f, 0.9f * half.ReduceMin());
        shape = new BoxShape(half, radius);
        break;
    }
    case STUDIO_JOLT_SPHERE:
        if (paramCount < 1) return STUDIO_JOLT_NO_BODY;
        shape = new SphereShape(std::max(params[0], 0.01f));
        break;
    case STUDIO_JOLT_CYLINDER: {
        if (paramCount < 2) return STUDIO_JOLT_NO_BODY;
        float halfHeight = std::max(params[0], 0.01f), radius = std::max(params[1], 0.01f);
        shape = new CylinderShape(halfHeight, radius, std::min(0.05f, 0.9f * std::min(halfHeight, radius)));
        break;
    }
    case STUDIO_JOLT_CAPSULE:
        if (paramCount < 2) return STUDIO_JOLT_NO_BODY;
        shape = new CapsuleShape(std::max(params[0], 0.01f), std::max(params[1], 0.01f));
        break;
    case STUDIO_JOLT_HULL: {
        if (pointCount < 4) return STUDIO_JOLT_NO_BODY;
        Array<Vec3> hull;
        for (int i = 0; i < pointCount; i++) hull.push_back(Vec3(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]));
        ConvexHullShapeSettings settings(hull, 0.02f);
        ShapeSettings::ShapeResult result = settings.Create();
        if (result.HasError()) return STUDIO_JOLT_NO_BODY;
        shape = result.Get();
        break;
    }
    default:
        return STUDIO_JOLT_NO_BODY;
    }
    world->pendingShapes.push_back(shape);
    return (uint32_t)(world->pendingShapes.size() - 1);
}

uint32_t studio_jolt_add_compound(StudioJoltWorld *world, const uint32_t *shapes, const float *positions,
                                  const float *rotations, int count,
                                  const float *position, const float *rotation, int motion,
                                  float mass, float friction, float restitution, int canCollide) {
    RefConst<Shape> shape;
    bool valid = count > 0;
    for (int i = 0; i < count && valid; i++) valid = shapes[i] < world->pendingShapes.size();
    if (valid && count == 1 && Vec3(positions[0], positions[1], positions[2]).IsNearZero()
        && Quat(rotations[0], rotations[1], rotations[2], rotations[3]).IsClose(Quat::sIdentity())) {
        shape = world->pendingShapes[shapes[0]];
    } else if (valid) {
        StaticCompoundShapeSettings compound;
        for (int i = 0; i < count; i++) {
            compound.AddShape(Vec3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]),
                              Quat(rotations[i * 4], rotations[i * 4 + 1], rotations[i * 4 + 2], rotations[i * 4 + 3]).Normalized(),
                              world->pendingShapes[shapes[i]]);
        }
        ShapeSettings::ShapeResult result = compound.Create();
        if (result.HasError()) valid = false; else shape = result.Get();
    }
    world->pendingShapes.clear();
    if (!valid) return STUDIO_JOLT_NO_BODY;

    bool dynamic = motion == STUDIO_JOLT_DYNAMIC;
    bool kinematic = motion == STUDIO_JOLT_KINEMATIC;
    ObjectLayer layer = kinematic ? Layers::Character
        : (!canCollide ? Layers::Ghost : (dynamic ? Layers::Moving : Layers::Static));
    BodyCreationSettings settings(shape, RVec3(vec(position)),
                                  Quat(rotation[0], rotation[1], rotation[2], rotation[3]).Normalized(),
                                  dynamic ? EMotionType::Dynamic : (kinematic ? EMotionType::Kinematic : EMotionType::Static),
                                  layer);
    settings.mFriction = friction;
    settings.mRestitution = restitution;
    if (dynamic) {
        settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = std::max(mass, 0.01f);
        // Swept collision, so fast parts don't pass through thin ones.
        settings.mMotionQuality = EMotionQuality::LinearCast;
        settings.mMaxLinearVelocity = 2000.0f;
        settings.mMaxAngularVelocity = 80.0f;
        settings.mAllowSleeping = true;
        settings.mLinearDamping = 0.01f;
        settings.mAngularDamping = 0.05f;
    }
    Body *body = world->bodies().CreateBody(settings);
    if (!body) return STUDIO_JOLT_NO_BODY;
    uint32_t id = body->GetID().GetIndexAndSequenceNumber();
    body->SetCollisionGroup(CollisionGroup(world->jointFilter, 0, id));
    world->bodies().AddBody(body->GetID(), dynamic || kinematic ? EActivation::Activate : EActivation::DontActivate);
    return id;
}

uint32_t studio_jolt_add_body(StudioJoltWorld *world, int shapeKind, const float *params, int paramCount,
                              const float *points, int pointCount,
                              const float *position, const float *rotation, int motion,
                              float mass, float friction, float restitution, int canCollide) {
    uint32_t shape = studio_jolt_make_shape(world, shapeKind, params, paramCount, points, pointCount);
    if (shape == STUDIO_JOLT_NO_BODY) return STUDIO_JOLT_NO_BODY;
    const float origin[3] = { 0, 0, 0 };
    const float identity[4] = { 0, 0, 0, 1 };
    return studio_jolt_add_compound(world, &shape, origin, identity, 1, position, rotation, motion,
                                    mass, friction, restitution, canCollide);
}

void studio_jolt_remove_body(StudioJoltWorld *world, uint32_t id) {
    removeJointsOf(world, id);
    BodyID body(id);
    world->bodies().RemoveBody(body);
    world->bodies().DestroyBody(body);
}

void studio_jolt_set_pose(StudioJoltWorld *world, uint32_t id, const float *position, const float *rotation) {
    BodyID body(id);
    BodyInterface &bodies = world->bodies();
    bool dynamic = bodies.GetMotionType(body) == EMotionType::Dynamic;
    bodies.SetPositionAndRotation(body, RVec3(vec(position)),
                                  Quat(rotation[0], rotation[1], rotation[2], rotation[3]).Normalized(),
                                  dynamic ? EActivation::Activate : EActivation::DontActivate);
}

void studio_jolt_get_pose(StudioJoltWorld *world, uint32_t id, float *position, float *rotation) {
    RVec3 p;
    Quat q;
    world->bodies().GetPositionAndRotation(BodyID(id), p, q);
    store(Vec3(p), position);
    rotation[0] = q.GetX(); rotation[1] = q.GetY(); rotation[2] = q.GetZ(); rotation[3] = q.GetW();
}

void studio_jolt_set_velocity(StudioJoltWorld *world, uint32_t id, const float *linear) {
    world->bodies().SetLinearVelocity(BodyID(id), vec(linear));
    world->bodies().ActivateBody(BodyID(id));
}

void studio_jolt_get_velocity(StudioJoltWorld *world, uint32_t id, float *linear) {
    store(world->bodies().GetLinearVelocity(BodyID(id)), linear);
}

void studio_jolt_set_angular_velocity(StudioJoltWorld *world, uint32_t id, const float *angular) {
    world->bodies().SetAngularVelocity(BodyID(id), vec(angular));
    world->bodies().ActivateBody(BodyID(id));
}

void studio_jolt_get_angular_velocity(StudioJoltWorld *world, uint32_t id, float *angular) {
    store(world->bodies().GetAngularVelocity(BodyID(id)), angular);
}

void studio_jolt_add_impulse(StudioJoltWorld *world, uint32_t id, const float *impulse) {
    world->bodies().AddImpulse(BodyID(id), vec(impulse));
}

void studio_jolt_add_angular_impulse(StudioJoltWorld *world, uint32_t id, const float *impulse) {
    world->bodies().AddAngularImpulse(BodyID(id), vec(impulse));
}

void studio_jolt_set_collides(StudioJoltWorld *world, uint32_t id, int canCollide) {
    BodyID body(id);
    BodyInterface &bodies = world->bodies();
    bool dynamic = bodies.GetMotionType(body) == EMotionType::Dynamic;
    bodies.SetObjectLayer(body, !canCollide ? Layers::Ghost : (dynamic ? Layers::Moving : Layers::Static));
}

void studio_jolt_wake(StudioJoltWorld *world, uint32_t id) {
    world->bodies().ActivateBody(BodyID(id));
}

void studio_jolt_move_kinematic(StudioJoltWorld *world, uint32_t id, const float *position,
                                const float *rotation, float dt) {
    world->bodies().MoveKinematic(BodyID(id), RVec3(vec(position)),
                                  Quat(rotation[0], rotation[1], rotation[2], rotation[3]).Normalized(),
                                  std::max(dt, 1e-4f));
}

int studio_jolt_is_awake(StudioJoltWorld *world, uint32_t id) {
    return world->bodies().IsActive(BodyID(id)) ? 1 : 0;
}

float studio_jolt_mass(StudioJoltWorld *world, uint32_t id) {
    BodyLockRead lock(world->system.GetBodyLockInterface(), BodyID(id));
    if (!lock.Succeeded()) return 0;
    const Body &body = lock.GetBody();
    if (!body.IsDynamic()) return 0;
    float inverse = body.GetMotionProperties()->GetInverseMass();
    return inverse > 0 ? 1.0f / inverse : 0;
}

void studio_jolt_step(StudioJoltWorld *world, float dt, int collisionSteps) {
    world->system.Update(dt, std::max(collisionSteps, 1), &world->temp, &world->jobs);
}

int studio_jolt_awake_bodies(StudioJoltWorld *world, uint32_t *out, int capacity) {
    BodyIDVector active;
    world->system.GetActiveBodies(EBodyType::RigidBody, active);
    int count = 0;
    for (BodyID id : active) {
        if (count < capacity) out[count] = id.GetIndexAndSequenceNumber();
        count++;
    }
    return count;
}

int studio_jolt_drain_contacts(StudioJoltWorld *world, uint32_t *out, int capacity) {
    std::vector<uint32_t> events = world->contacts.drain();
    int pairs = (int)(events.size() / 5);
    int copy = std::min(pairs, capacity);
    const BodyLockInterfaceNoLock &locks = world->system.GetBodyLockInterfaceNoLock();
    // Which of a compound body's shapes touched: the part within a welded assembly.
    auto child = [&](uint32_t body, uint32_t raw) -> uint32_t {
        BodyLockRead lock(locks, BodyID(body));
        if (!lock.Succeeded()) return 0;
        const Shape *shape = lock.GetBody().GetShape();
        if (shape->GetSubType() != EShapeSubType::StaticCompound) return 0;
        SubShapeID id;
        id.SetValue(raw);
        SubShapeID remainder;
        return static_cast<const CompoundShape *>(shape)->GetSubShapeIndexFromID(id, remainder);
    };
    for (int i = 0; i < copy; i++) {
        const uint32_t *e = &events[i * 5];
        out[i * 5] = e[0];
        out[i * 5 + 1] = child(e[0], e[1]);
        out[i * 5 + 2] = e[2];
        out[i * 5 + 3] = child(e[2], e[3]);
        out[i * 5 + 4] = e[4];
    }
    return pairs;
}

uint32_t studio_jolt_add_joint(StudioJoltWorld *world, int kind, uint32_t bodyA, uint32_t bodyB,
                               const float *pointA, const float *pointB,
                               const float *axisA, const float *axisB,
                               const float *normalA, const float *normalB,
                               const float *values, int valueCount, int noCollide) {
    auto value = [&](int i, float fallback) { return i < valueCount ? values[i] : fallback; };
    Ref<TwoBodyConstraintSettings> settings;
    switch (kind) {
    case STUDIO_JOLT_HINGE: {
        auto *hinge = new HingeConstraintSettings();
        hinge->mSpace = EConstraintSpace::WorldSpace;
        hinge->mPoint1 = RVec3(vec(pointA));
        hinge->mPoint2 = RVec3(vec(pointB));
        hinge->mHingeAxis1 = vec(axisA).Normalized();
        hinge->mHingeAxis2 = vec(axisB).Normalized();
        hinge->mNormalAxis1 = vec(normalA).Normalized();
        hinge->mNormalAxis2 = vec(normalB).Normalized();
        if (value(0, 0) > 0.5f) {
            hinge->mLimitsMin = std::clamp(value(1, -JPH_PI), -JPH_PI, 0.0f);
            hinge->mLimitsMax = std::clamp(value(2, JPH_PI), 0.0f, JPH_PI);
        }
        settings = hinge;
        break;
    }
    case STUDIO_JOLT_POINT: {
        auto *point = new PointConstraintSettings();
        point->mSpace = EConstraintSpace::WorldSpace;
        point->mPoint1 = RVec3(vec(pointA));
        point->mPoint2 = RVec3(vec(pointB));
        settings = point;
        break;
    }
    case STUDIO_JOLT_ROPE:
    case STUDIO_JOLT_SPRING: {
        auto *distance = new DistanceConstraintSettings();
        distance->mSpace = EConstraintSpace::WorldSpace;
        distance->mPoint1 = RVec3(vec(pointA));
        distance->mPoint2 = RVec3(vec(pointB));
        if (kind == STUDIO_JOLT_ROPE) {
            distance->mMinDistance = 0;
            distance->mMaxDistance = std::max(value(0, 1), 0.01f);
        } else {
            float length = std::max(value(0, 1), 0.01f);
            distance->mMinDistance = length;
            distance->mMaxDistance = length;
            distance->mLimitsSpringSettings.mMode = ESpringMode::StiffnessAndDamping;
            distance->mLimitsSpringSettings.mStiffness = std::max(value(1, 100), 0.0f);
            distance->mLimitsSpringSettings.mDamping = std::max(value(2, 1), 0.0f);
        }
        settings = distance;
        break;
    }
    case STUDIO_JOLT_SLIDER: {
        auto *slider = new SliderConstraintSettings();
        slider->mSpace = EConstraintSpace::WorldSpace;
        slider->mPoint1 = RVec3(vec(pointA));
        slider->mPoint2 = RVec3(vec(pointB));
        slider->mSliderAxis1 = vec(axisA).Normalized();
        slider->mSliderAxis2 = vec(axisB).Normalized();
        slider->mNormalAxis1 = vec(normalA).Normalized();
        slider->mNormalAxis2 = vec(normalB).Normalized();
        if (value(0, 0) > 0.5f) {
            slider->mLimitsMin = std::min(value(1, -1), 0.0f);
            slider->mLimitsMax = std::max(value(2, 1), 0.0f);
        }
        settings = slider;
        break;
    }
    case STUDIO_JOLT_MOTOR: {
        // Every axis free, and a stiff spring on each holding it where it's driven.
        auto *six = new SixDOFConstraintSettings();
        six->mSpace = EConstraintSpace::WorldSpace;
        six->mPosition1 = RVec3(vec(pointA));
        six->mPosition2 = RVec3(vec(pointB));
        six->mAxisX1 = vec(axisA).Normalized();
        six->mAxisY1 = vec(normalA).Normalized();
        six->mAxisX2 = vec(axisB).Normalized();
        six->mAxisY2 = vec(normalB).Normalized();
        for (int axis = 0; axis < SixDOFConstraintSettings::EAxis::Num; ++axis) {
            six->mMotorSettings[axis] = MotorSettings(25.0f, 1.0f);
        }
        settings = six;
        break;
    }
    default:
        return STUDIO_JOLT_NO_BODY;
    }

    TwoBodyConstraint *constraint = world->bodies().CreateConstraint(settings, BodyID(bodyA), BodyID(bodyB));
    if (!constraint) return STUDIO_JOLT_NO_BODY;
    if (kind == STUDIO_JOLT_MOTOR) {
        auto *six = static_cast<SixDOFConstraint *>(constraint);
        for (int axis = 0; axis < SixDOFConstraintSettings::EAxis::Num; ++axis) {
            six->SetMotorState(SixDOFConstraintSettings::EAxis(axis), EMotorState::Position);
        }
    }
    world->system.AddConstraint(constraint);
    world->bodies().ActivateConstraint(constraint);
    if (noCollide) world->jointFilter->pairs[JointFilter::key(bodyA, bodyB)] += 1;
    uint32_t id = world->nextJoint++;
    world->joints[id] = Joint { constraint, kind, bodyA, bodyB, noCollide != 0 };
    return id;
}

void studio_jolt_remove_joint(StudioJoltWorld *world, uint32_t id) {
    auto found = world->joints.find(id);
    if (found == world->joints.end()) return;
    Joint &joint = found->second;
    world->bodies().ActivateConstraint(joint.constraint);
    world->system.RemoveConstraint(joint.constraint);
    if (joint.noCollide) {
        auto pair = world->jointFilter->pairs.find(JointFilter::key(joint.a, joint.b));
        if (pair != world->jointFilter->pairs.end() && --pair->second <= 0) world->jointFilter->pairs.erase(pair);
    }
    world->joints.erase(found);
}

void studio_jolt_ignore_pair(StudioJoltWorld *world, uint32_t a, uint32_t b, int on) {
    auto key = JointFilter::key(a, b);
    if (on) {
        world->jointFilter->pairs[key] += 1;
    } else {
        auto pair = world->jointFilter->pairs.find(key);
        if (pair != world->jointFilter->pairs.end() && --pair->second <= 0) world->jointFilter->pairs.erase(pair);
    }
    // Bodies already touching find out at once.
    world->bodies().ActivateBody(BodyID(a));
    world->bodies().ActivateBody(BodyID(b));
}

void studio_jolt_drive_joint(StudioJoltWorld *world, uint32_t id, int on, float speed, float limit) {
    auto found = world->joints.find(id);
    if (found == world->joints.end()) return;
    Joint &joint = found->second;
    if (joint.kind == STUDIO_JOLT_HINGE) {
        auto *hinge = static_cast<HingeConstraint *>(joint.constraint.GetPtr());
        hinge->GetMotorSettings().SetTorqueLimit(std::max(limit, 0.0f));
        hinge->SetMotorState(on ? EMotorState::Velocity : EMotorState::Off);
        hinge->SetTargetAngularVelocity(speed);
    } else if (joint.kind == STUDIO_JOLT_SLIDER) {
        auto *slider = static_cast<SliderConstraint *>(joint.constraint.GetPtr());
        slider->GetMotorSettings().SetForceLimit(std::max(limit, 0.0f));
        slider->SetMotorState(on ? EMotorState::Velocity : EMotorState::Off);
        slider->SetTargetVelocity(speed);
    } else {
        return;
    }
    if (on) world->bodies().ActivateConstraint(joint.constraint);
}

void studio_jolt_drive_motor(StudioJoltWorld *world, uint32_t id, const float *position, const float *rotation) {
    auto found = world->joints.find(id);
    if (found == world->joints.end() || found->second.kind != STUDIO_JOLT_MOTOR) return;
    auto *six = static_cast<SixDOFConstraint *>(found->second.constraint.GetPtr());
    six->SetTargetPositionCS(vec(position));
    six->SetTargetOrientationCS(Quat(rotation[0], rotation[1], rotation[2], rotation[3]).Normalized());
    world->bodies().ActivateConstraint(found->second.constraint);
}

void studio_jolt_inertia_times(StudioJoltWorld *world, uint32_t id, const float *spin, float *out) {
    out[0] = out[1] = out[2] = 0;
    BodyLockRead lock(world->system.GetBodyLockInterface(), BodyID(id));
    if (!lock.Succeeded() || !lock.GetBody().IsDynamic()) return;
    Mat44 inverse = lock.GetBody().GetInverseInertia();
    if (std::abs(inverse.GetDeterminant3x3()) < 1e-30f) return;
    Vec3 result = inverse.Inversed3x3().Multiply3x3(vec(spin));
    if (!std::isfinite(result.GetX()) || !std::isfinite(result.GetY()) || !std::isfinite(result.GetZ())) return;
    out[0] = result.GetX();
    out[1] = result.GetY();
    out[2] = result.GetZ();
}

float studio_jolt_joint_value(StudioJoltWorld *world, uint32_t id) {
    auto found = world->joints.find(id);
    if (found == world->joints.end()) return 0;
    Joint &joint = found->second;
    if (joint.kind == STUDIO_JOLT_HINGE) return static_cast<HingeConstraint *>(joint.constraint.GetPtr())->GetCurrentAngle();
    if (joint.kind == STUDIO_JOLT_SLIDER) return static_cast<SliderConstraint *>(joint.constraint.GetPtr())->GetCurrentPosition();
    return 0;
}

} // extern "C"

namespace {
void removeJointsOf(StudioJoltWorld *world, uint32_t body) {
    std::vector<uint32_t> doomed;
    for (auto &entry : world->joints) {
        if (entry.second.a == body || entry.second.b == body) doomed.push_back(entry.first);
    }
    for (uint32_t id : doomed) studio_jolt_remove_joint(world, id);
}
}
