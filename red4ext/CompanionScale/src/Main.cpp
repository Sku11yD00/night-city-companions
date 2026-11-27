// CompanionScale -- draws chosen people larger (or smaller) than life. A RED4ext plugin for Night City Companions.
//
// A character's body is skinned meshes, and a skinned mesh has no visualScale, so the prop-scaling trick other mods
// use does nothing to a person. What is drawn comes from the animation pose, though: this plugin detours the engine's
// pose-apply function (the one every skeleton goes through, every frame) and, after the engine's own animation, writes
// a scale into the pose of the people it was asked to scale.
//
// The approach and the engine details (the pose-apply offset, the pose descriptor's layout, finding a person's
// animated object through the world animation system) come from the Cyberpunk VR Port by dariulone, MIT licensed:
// https://github.com/dariulone/cyberpunk-vr-port (src/Hooks/AnimPose.cpp, src/Natives/AnimLookup.cpp,
// src/Anim/NpcArmGrip.cpp).
//
// Script API (a global native, callable from CET as Game.CompanionScale or CompanionScale, and from redscript):
//   CompanionScale(entity: ref<IScriptable>, scale: Float, mode: Int32) -> Bool
//     Draws the person at `scale` (0.05 to 50). Ask again at least every 2.5 s to keep it (the Lua mod asks twice a
//     second); a person not asked about for longer is let go, so a despawned person's reused buffers are never touched.
//     scale 1 lets them go at once. Which mode is right depends on how the engine carries a parent's scale down the
//     bone chain, and is picked by eye:
//       mode 2  the Root's scale and every bone's translation (scale is inherited, but does not stretch the offsets
//               between joints -- what the game does, as far as testing shows; the Lua mod's default)
//       mode 0  the Root's scale only (scale and offsets both inherited; in game this swells each body part in place)
//       mode 1  every bone's translation and scale (nothing inherited)
//
// Not scaled: the collision capsule, the navigation agent, the ragdoll and the culling bounds.
#include <RED4ext/RED4ext.hpp>
#include <RED4ext/GameEngine.hpp>
// worldAnimationSystem.hpp uses StaticArray without including it
#include <RED4ext/Containers/StaticArray.hpp>
#include <RED4ext/Scripting/Natives/entEntity.hpp>
#include <RED4ext/Scripting/Natives/animAnimatedObject.hpp>
#include <RED4ext/Scripting/Natives/worldAnimationSystem.hpp>
#include <RED4ext/Scripting/Natives/worldAnimationSystemScriptInterface.hpp>
#include <RED4ext/Scripting/Natives/Generated/ent/AnimatedComponent.hpp>

#include <windows.h>
#include <cstdint>
#include <cstring>

namespace
{
const RED4ext::v1::Sdk* g_sdk = nullptr;
RED4ext::v1::PluginHandle g_handle = nullptr;

// ------------------------------------------------------------------------------------------------ the scaled people

constexpr int kMost = 8;                // people scaled at once
constexpr uint64_t kStaleMs = 2500;     // not asked about for this long: let go
constexpr int kBoneStride = 48;         // QsTransform: Translation (16), Rotation (16), Scale (16)
constexpr int kTransOff = 0, kScaleOff = 32;
constexpr uint32_t kMostBones = 2048;
constexpr float kLeast = .05f, kMostScale = 50.f;

struct Scaled
{
    bool on;
    uintptr_t entity;                   // identity only, never dereferenced
    uintptr_t trackA, trackB;           // the buffers this person's pose passes carry
    float scale;
    int mode;
    uint64_t asked;
};
Scaled g_people[kMost]{};
SRWLOCK g_lock = SRWLOCK_INIT;
volatile LONG g_anyOn = 0;

inline float* LocalT(uint8_t* buf, uint32_t i) { return reinterpret_cast<float*>(buf + i * kBoneStride + kTransOff); }
inline float* LocalS(uint8_t* buf, uint32_t i) { return reinterpret_cast<float*>(buf + i * kBoneStride + kScaleOff); }

// The engine can hand the same buffer to the hook twice, so a write must not land on top of itself. Mode 0 sets the
// Root's scale outright (the same however often it runs). Modes 1 and 2 multiply, so the last few buffers it wrote are
// remembered with what one bone was left at; a buffer that still has that is already done.
struct Done { uint8_t* buf; float t[3]; };
Done g_done[16]{};
volatile LONG g_doneNext = 0;
uint32_t WatchBone(uint32_t slots) { return slots > 2 ? 2u : 0u; }   // Hips on the man/woman base rigs

bool AlreadyDone(uint8_t* buf, uint32_t slots)
{
    const float* t = LocalT(buf, WatchBone(slots));
    for (const auto& d : g_done)
        if (d.buf == buf && d.t[0] == t[0] && d.t[1] == t[1] && d.t[2] == t[2]) return true;
    return false;
}

void NoteDone(uint8_t* buf, uint32_t slots)
{
    const LONG i = (InterlockedIncrement(&g_doneNext) - 1) & 15;
    const float* t = LocalT(buf, WatchBone(slots));
    g_done[i].buf = buf;
    g_done[i].t[0] = t[0]; g_done[i].t[1] = t[1]; g_done[i].t[2] = t[2];
}

void Write(uint8_t* buf, uint32_t slots, const Scaled& p)
{
    const float s = p.scale;
    if (p.mode == 1)
    {
        if (AlreadyDone(buf, slots)) return;
        for (uint32_t i = 0; i < slots; ++i)
        {
            float* t = LocalT(buf, i);
            float* sc = LocalS(buf, i);
            t[0] *= s; t[1] *= s; t[2] *= s;
            sc[0] *= s; sc[1] *= s; sc[2] *= s;
        }
        NoteDone(buf, slots);
    }
    else if (p.mode == 2)
    {
        if (AlreadyDone(buf, slots)) return;
        for (uint32_t i = 0; i < slots; ++i)
        {
            float* t = LocalT(buf, i);
            t[0] *= s; t[1] *= s; t[2] *= s;
        }
        float* sc = LocalS(buf, 0);
        sc[0] = s; sc[1] = s; sc[2] = s;
        NoteDone(buf, slots);
    }
    else
    {
        float* sc = LocalS(buf, 0);
        sc[0] = s; sc[1] = s; sc[2] = s;
    }
}

void ApplyInner(void* a2)
{
    void* poseDesc = reinterpret_cast<void**>(a2)[7];
    if (!poseDesc) return;
    auto* boneBuf = reinterpret_cast<uint8_t**>(poseDesc)[0];
    const uintptr_t trackBuf = reinterpret_cast<uintptr_t*>(poseDesc)[3];
    if (!boneBuf || !trackBuf) return;
    const uint32_t slots = *reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(poseDesc) + 8);
    if (slots == 0 || slots > kMostBones) return;
    const uint64_t now = GetTickCount64();
    for (const auto& p : g_people)
    {
        if (!p.on || (trackBuf != p.trackA && trackBuf != p.trackB)) continue;
        if (now - p.asked > kStaleMs) continue;
        Write(boneBuf, slots, p);
        return;
    }
}

void Apply(void* a2)
{
    if (!g_anyOn) return;
    AcquireSRWLockShared(&g_lock);
    __try
    {
        ApplyInner(a2);
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
    }
    ReleaseSRWLockShared(&g_lock);
}

// ------------------------------------------------------------------------------------------------ the pose hook

// The engine's pose apply, for every skeleton, every frame. Offset measured on game 2.50 (the VR port's AnimPose.cpp);
// the plugin declares runtime 2.50, so RED4ext does not load it on another version.
constexpr uintptr_t kPoseApplyRva = 0x1B3C08;
using PoseApply_t = void* (*)(void*, void*, void*, unsigned int);
PoseApply_t g_originalPoseApply = nullptr;

void* DetouredPoseApply(void* a1, void* a2, void* a3, unsigned int a4)
{
    void* result = g_originalPoseApply(a1, a2, a3, a4);
    Apply(a2);
    return result;
}

// ------------------------------------------------------------------------------------------------ finding a person

// The world animation system is not reliably handed out as a game system (in game 2.5 that lookup gives nothing), so
// it is found the way the VR port finds it: from the person's runtime scene, at scene+0x8 -> +0x38, checked by its type
// name; failing that, by looking through the scene's pointers (and one level below them) for an object of that type.
// Found once, then remembered while it still checks out.
RED4ext::world::AnimationSystem* g_animationSystem = nullptr;
const char* g_systemHow = "not found";

bool Readable(const void* p, size_t n)
{
    const auto v = reinterpret_cast<uintptr_t>(p);
    if (v < 0x10000 || v >= 0x0000800000000000ull || (v & 7)) return false;
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return false;
    if (mbi.State != MEM_COMMIT) return false;
    const DWORD prot = mbi.Protect & 0xFF;
    if (prot == PAGE_NOACCESS || prot == 0 || (mbi.Protect & PAGE_GUARD)) return false;
    return v + n <= reinterpret_cast<uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
}

uint64_t ReadQword(const void* base, size_t off)
{
    __try
    {
        return *reinterpret_cast<const uint64_t*>(static_cast<const uint8_t*>(base) + off);
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return 0;
    }
}

// 1 the animation system itself, 2 its script interface, 0 neither. p must be readable.
int KindOf(void* p)
{
    __try
    {
        // an object's first qword is its vtable, which lives in the game's image
        const uint64_t vtable = *reinterpret_cast<uint64_t*>(p);
        const auto exe = reinterpret_cast<uint64_t>(GetModuleHandleW(nullptr));
        if (vtable < exe || vtable > exe + 0x10000000ull) return 0;
        auto* type = reinterpret_cast<RED4ext::ISerializable*>(p)->GetType();
        if (!type) return 0;
        if (type->name == "worldAnimationSystem") return 1;
        if (type->name == "worldAnimationSystemScriptInterface") return 2;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
    }
    return 0;
}

RED4ext::world::AnimationSystem* AsSystem(uint64_t candidate)
{
    auto* p = reinterpret_cast<void*>(candidate);
    if (!Readable(p, 0x40)) return nullptr;
    const int kind = KindOf(p);
    if (kind == 1) return reinterpret_cast<RED4ext::world::AnimationSystem*>(p);
    if (kind == 2)
    {
        auto* inner = reinterpret_cast<RED4ext::world::AnimationSystemScriptInterface*>(p)->animationSystem;
        if (Readable(inner, 0x40) && KindOf(inner) == 1) return inner;
    }
    return nullptr;
}

RED4ext::world::AnimationSystem* ScanBlock(const void* block, size_t size)
{
    if (!Readable(block, size)) return nullptr;
    for (size_t off = 0; off + 8 <= size; off += 8)
    {
        const uint64_t p = ReadQword(block, off);
        if (auto* sys = AsSystem(p)) return sys;
        if (!Readable(reinterpret_cast<void*>(p), 0x200)) continue;
        for (size_t inner = 0; inner + 8 <= 0x200; inner += 8)
            if (auto* sys = AsSystem(ReadQword(reinterpret_cast<void*>(p), inner))) return sys;
    }
    return nullptr;
}

RED4ext::world::RuntimeScene* SceneOf(RED4ext::ent::Entity* entity)
{
    __try
    {
        return entity->runtimeScene;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return nullptr;
    }
}

RED4ext::world::AnimationSystem* WorldAnimationSystem(RED4ext::ent::Entity* entity)
{
    if (g_animationSystem && Readable(g_animationSystem, 0x40) && KindOf(g_animationSystem) == 1)
        return g_animationSystem;
    g_animationSystem = nullptr;
    g_systemHow = "not found";

    // as a game system
    auto* engine = RED4ext::CGameEngine::Get();
    auto* framework = engine ? engine->framework : nullptr;
    auto* gameInstance = framework ? framework->gameInstance : nullptr;
    auto* rtti = RED4ext::CRTTISystem::Get();
    auto* cls = rtti ? rtti->GetClass("worldAnimationSystemScriptInterface") : nullptr;
    if (gameInstance && cls)
    {
        if (auto* sys = AsSystem(reinterpret_cast<uint64_t>(gameInstance->GetSystem(cls))))
        {
            g_systemHow = "game system";
            return g_animationSystem = sys;
        }
    }
    // from the person's scene
    auto* scene = entity ? SceneOf(entity) : nullptr;
    if (Readable(scene, 0x10))
    {
        const uint64_t parent = ReadQword(scene, 0x8);
        if (Readable(reinterpret_cast<void*>(parent), 0x40))
        {
            if (auto* sys = AsSystem(ReadQword(reinterpret_cast<void*>(parent), 0x38)))
            {
                g_systemHow = "scene chain";
                return g_animationSystem = sys;
            }
        }
        // the scans are slow (a memory query per pointer): at most one round every 5 seconds
        static uint64_t s_lastScan = 0;
        const uint64_t now = GetTickCount64();
        if (s_lastScan && now - s_lastScan < 5000) return nullptr;
        s_lastScan = now;
        if (auto* sys = ScanBlock(scene, 0x4B8))
        {
            g_systemHow = "scene scan";
            return g_animationSystem = sys;
        }
    }
    if (framework)
    {
        if (auto* sys = ScanBlock(reinterpret_cast<void*>(framework->unk18), 0x800))
        {
            g_systemHow = "framework scan";
            return g_animationSystem = sys;
        }
    }
    return nullptr;
}

// What the last search saw, for the log: why a person could not be found is the whole question when sizes do nothing.
struct Search
{
    bool system = false;
    int byId = 0;          // buckets whose entity id table had the person
    int byHandle = 0;      // slots whose entity handle was the person
    char names[160] = {};  // names of the animated components seen on them
    bool tracks = false;
};

void AddName(Search& s, const char* name)
{
    if (!name) name = "?";
    const size_t used = std::strlen(s.names);
    if (used + std::strlen(name) + 2 >= sizeof(s.names)) return;
    if (used) std::strcat(s.names, ",");
    std::strcat(s.names, name);
}

// One bucket: first by the entity id table (entity id -> slot), then by scanning the entity handles. A slot whose
// animated component is "root" wins; otherwise the first slot found is used.
RED4ext::anim::AnimatedObject* FindInBucket(RED4ext::world::AnimationSystem* system, uint32_t bucketIndex,
                                            RED4ext::ent::Entity* wanted, uint64_t wantedId, Search& s)
{
    RED4ext::anim::AnimatedObject* first = nullptr;
    __try
    {
        auto& bucket = system->entitityBuckets[bucketIndex];
        const uint32_t count = bucket.entities.Size();
        // the id table
        auto& map = bucket.entityIDs;
        if (map.size && map.indexTable && map.nodeList.nodes)
        {
            for (uint32_t i = 0; i < map.capacity; ++i)
            {
                for (uint32_t idx = map.indexTable[i]; idx != map.INVALID_INDEX; idx = map.nodeList.nodes[idx].next)
                {
                    auto& node = map.nodeList.nodes[idx];
                    if (node.key.hash != wantedId) continue;
                    ++s.byId;
                    const uint32_t slot = node.value;
                    if (slot < count && bucket.animatedObjects[slot])
                    {
                        auto* comp = bucket.animatedComponents[slot];
                        const char* name = comp ? comp->name.ToString() : nullptr;
                        AddName(s, name);
                        if (name && std::strcmp(name, "root") == 0) return bucket.animatedObjects[slot];
                        if (!first) first = bucket.animatedObjects[slot];
                    }
                }
            }
        }
        // the handles
        for (uint32_t i = 0; i < count; ++i)
        {
            if (reinterpret_cast<RED4ext::ent::Entity*>(bucket.entities[i].instance) != wanted) continue;
            ++s.byHandle;
            auto* comp = bucket.animatedComponents[i];
            const char* name = comp ? comp->name.ToString() : nullptr;
            AddName(s, name);
            if (name && std::strcmp(name, "root") == 0) return bucket.animatedObjects[i];
            if (!first) first = bucket.animatedObjects[i];
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
    }
    return first;
}

uint64_t EntityIdOf(RED4ext::ent::Entity* entity)
{
    __try
    {
        return entity->entityID.hash;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return 0;
    }
}

RED4ext::anim::AnimatedObject* FindAnimatedObjectOf(RED4ext::ent::Entity* wanted, Search& s)
{
    auto* system = WorldAnimationSystem(wanted);
    s.system = system != nullptr;
    if (!system || !wanted) return nullptr;
    const uint64_t id = EntityIdOf(wanted);
    RED4ext::anim::AnimatedObject* fallback = nullptr;
    for (uint32_t b = 0; b < RED4ext::world::AnimationSystem::BucketCount; ++b)
    {
        auto* object = FindInBucket(system, b, wanted, id, s);
        if (object && std::strstr(s.names, "root")) return object;
        if (object && !fallback) fallback = object;
    }
    return fallback;
}

// The two track buffers a person's pose passes carry, from their animated object.
bool TracksOf(RED4ext::ent::Entity* entity, uintptr_t& a, uintptr_t& b, Search& s)
{
    auto* object = FindAnimatedObjectOf(entity, s);
    if (!object) return false;
    __try
    {
        const auto* base = reinterpret_cast<uint8_t*>(object);
        const auto ownerA = *reinterpret_cast<const uintptr_t*>(base + 8);
        const auto ownerB = *reinterpret_cast<const uintptr_t*>(base + 0x18);
        a = ownerA ? *reinterpret_cast<uintptr_t*>(ownerA + 0x40) : 0;
        b = ownerB ? *reinterpret_cast<uintptr_t*>(ownerB + 0x18) : 0;
        s.tracks = a || b;
        return s.tracks;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

bool SetScale(void* entityPtr, float scale, int32_t mode)
{
    if (!entityPtr) return false;
    const auto key = reinterpret_cast<uintptr_t>(entityPtr);
    const bool release = !(scale > 0.f) || (scale > .999f && scale < 1.001f);
    if (scale < kLeast) scale = kLeast;
    if (scale > kMostScale) scale = kMostScale;
    uintptr_t a = 0, b = 0;
    Search search;
    const bool found = !release && TracksOf(reinterpret_cast<RED4ext::ent::Entity*>(entityPtr), a, b, search);
    // a person who cannot be scaled is reported once (per person), with what the search saw
    static uintptr_t s_reported = 0;
    if (!release && !found && s_reported != key && g_sdk)
    {
        s_reported = key;
        g_sdk->logger->InfoF(g_handle,
                             "cannot scale a person: animation system %s, in id tables %d, by handle %d, "
                             "components [%s], track buffers %s",
                             search.system ? g_systemHow : "MISSING", search.byId, search.byHandle, search.names,
                             search.tracks ? "found" : "missing");
    }
    const uint64_t now = GetTickCount64();
    bool answer = false;
    bool fresh = false;
    AcquireSRWLockExclusive(&g_lock);
    Scaled* slot = nullptr;
    Scaled* free = nullptr;
    for (auto& p : g_people)
    {
        if (p.on && p.entity == key) slot = &p;
        else if (!free && (!p.on || now - p.asked > kStaleMs)) free = &p;
    }
    if (release)
    {
        if (slot) slot->on = false;
        answer = true;
    }
    else if (found)
    {
        if (!slot) slot = free;
        if (slot)
        {
            fresh = !slot->on || slot->entity != key;
            slot->on = true;
            slot->entity = key;
            slot->trackA = a;
            slot->trackB = b;
            slot->scale = scale;
            slot->mode = (mode == 1 || mode == 2) ? mode : 0;
            slot->asked = now;
            answer = true;
        }
    }
    LONG any = 0;
    for (const auto& p : g_people)
        if (p.on) any = 1;
    InterlockedExchange(&g_anyOn, any);
    ReleaseSRWLockExclusive(&g_lock);
    if (fresh && g_sdk)
        g_sdk->logger->InfoF(g_handle, "scaling a person to %.2f (mode %d); animation system by %s, components [%s]",
                             scale, (mode == 1 || mode == 2) ? mode : 0, g_systemHow, search.names);
    return answer;
}

// ------------------------------------------------------------------------------------------------ script function

void CompanionScaleNative(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame, bool* aOut, int64_t)
{
    RED4ext::Handle<RED4ext::IScriptable> entity;
    float scale = 1.f;
    int32_t mode = 0;
    RED4ext::GetParameter(aFrame, &entity);
    RED4ext::GetParameter(aFrame, &scale);
    RED4ext::GetParameter(aFrame, &mode);
    aFrame->code++;
    const bool answer = SetScale(entity.instance, scale, mode);
    if (aOut) *aOut = answer;
}

void RegisterTypes() {}

void PostRegisterTypes()
{
    auto* rtti = RED4ext::CRTTISystem::Get();
    RED4ext::CBaseFunction::Flags flags = {.isNative = true, .isStatic = true};
    auto* func = RED4ext::CGlobalFunction::Create("CompanionScale", "CompanionScale", &CompanionScaleNative);
    func->flags = flags;
    func->AddParam("handle:IScriptable", "entity");
    func->AddParam("Float", "scale");
    func->AddParam("Int32", "mode");
    func->SetReturnType("Bool");
    rtti->RegisterFunction(func);
}
}  // namespace

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle, RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    switch (aReason)
    {
    case RED4ext::v1::EMainReason::Load:
    {
        g_sdk = aSdk;
        g_handle = aHandle;
        auto* rtti = RED4ext::CRTTISystem::Get();
        rtti->AddRegisterCallback(RegisterTypes);
        rtti->AddPostRegisterCallback(PostRegisterTypes);
        auto* exe = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        void* target = exe + kPoseApplyRva;
        if (!aSdk->hooking->Attach(aHandle, target, reinterpret_cast<void*>(&DetouredPoseApply),
                                   reinterpret_cast<void**>(&g_originalPoseApply)))
        {
            aSdk->logger->Error(aHandle, "could not hook the pose apply; sizes will not change");
        }
        else
        {
            aSdk->logger->Info(aHandle, "ready");
        }
        break;
    }
    case RED4ext::v1::EMainReason::Unload:
    {
        aSdk->hooking->Detach(aHandle, reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr)) + kPoseApplyRva);
        break;
    }
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"CompanionScale";
    aInfo->author = L"Night City Companions";
    aInfo->version = RED4EXT_V1_SEMVER(0, 1, 0);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_LATEST;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
