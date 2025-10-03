# Implementation Roadmap - Runtime Signature Verification

## Current Status: ✅ Planning Complete

This document tracks the implementation progress of the runtime signature verification POCs.

---

## Overview Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                     Container Signing POC Stack                     │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  📦 Image Signing                                                   │
│     ├─ Notation (custom plugins)     ✅ Implemented                │
│     ├─ Cosign (keyless/keyed)        ✅ Implemented                │
│     └─ Oras (signature relocation)   ✅ Implemented                │
│                                                                     │
│  🛡️ Verification Layers                                            │
│     ├─ Layer 1: Admission Control                                  │
│     │   └─ Kyverno Policies           ✅ Implemented                │
│     │                                                               │
│     └─ Layer 2: Runtime Verification  🚧 In Progress               │
│         ├─ CRI-O (native)             📋 Planned                   │
│         └─ Containerd (OCI hooks)     📋 Planned                   │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Planning & Documentation ✅ COMPLETE

### Deliverables
- [x] Detailed implementation plan (RUNTIME_VERIFICATION_PLAN.md)
- [x] Quick summary document (RUNTIME_VERIFICATION_SUMMARY.md)
- [x] Implementation roadmap (this file)
- [x] Updated main README.md with references

### Decisions Made
1. **CRI-O Approach**: VM-based (requires dedicated VM)
2. **Containerd Approach**: Kind-based (local testing, no VM needed)
3. **Implementation Order**: Recommend starting with Containerd (easier to test)
4. **Integration**: Reuse existing cosign infrastructure

---

## Phase 2: Containerd POC (Kind-based) 🎯 NEXT

**Why First**: Can be tested immediately without VM setup

### Tasks

#### 2.1 Directory Structure & Documentation
- [ ] Create containerd/README.md (comprehensive guide)
- [ ] Create containerd/Makefile (automation)
- [ ] Create directory structure (hooks/, config/, scripts/, manifests/, kind/)

#### 2.2 OCI Hook Implementation
- [ ] Write verify-signature.sh hook script
  - Read container state from stdin
  - Extract image name from annotations
  - Call cosign verify with appropriate flags
  - Return exit code (0=allow, 1=deny)
- [ ] Create hook configuration (config.json)
- [ ] Create containerd config with hook integration

#### 2.3 Kind Integration
- [ ] Create Kind cluster configuration YAML
- [ ] Create setup script for Kind cluster
- [ ] Script to inject hooks into Kind nodes
- [ ] Script to configure containerd in Kind

#### 2.4 Test Infrastructure
- [ ] Create test manifests (signed-pod.yaml, unsigned-pod.yaml)
- [ ] Create sign-images.sh script (reuse cosign infrastructure)
- [ ] Create test-verification.sh script
- [ ] Document manual testing steps

#### 2.5 Automation & Integration
- [ ] Complete Makefile with targets:
  - `make setup` - Setup Kind cluster with hooks
  - `make sign` - Sign test images
  - `make test` - Run verification tests
  - `make clean` - Cleanup
- [ ] Integration with existing cosign setup
- [ ] End-to-end test

#### 2.6 Documentation
- [ ] Complete README with:
  - Architecture overview
  - How OCI hooks work
  - Step-by-step setup guide
  - Troubleshooting section
  - Testing instructions
- [ ] Add diagrams and examples

**Estimated Time**: 4-5 hours

---

## Phase 3: CRI-O POC (VM-based) 🔜 AFTER CONTAINERD

**Why Second**: Requires VM setup, but simpler configuration

### Prerequisites
- User creates VM (Ubuntu 22.04/24.04 or Rocky Linux 9 recommended)
- VM has CRI-O installed
- VM has Kubernetes (kubeadm) or at minimum crictl

### Tasks

#### 3.1 Directory Structure & Documentation
- [ ] Create crio/README.md (comprehensive guide)
- [ ] Create crio/Makefile (automation)
- [ ] Create directory structure (config/, scripts/, manifests/, vm/)

#### 3.2 CRI-O Configuration
- [ ] Create policy.json for signature verification
  - Default: reject all
  - Local registry: accept anything (for testing)
  - Signed images: verify with cosign
- [ ] Create registries.d configuration for sigstore
- [ ] Create crio.conf.d snippet for signature verification

#### 3.3 VM Setup Scripts
- [ ] Create setup-vm.sh (install dependencies)
- [ ] Create configure-crio.sh (apply configurations)
- [ ] Create Vagrantfile (optional, for easy VM creation)
- [ ] Create cloud-init.yaml (for cloud providers)

#### 3.4 Test Infrastructure
- [ ] Create test manifests (signed-pod.yaml, unsigned-pod.yaml)
- [ ] Create sign-images.sh script (reuse cosign infrastructure)
- [ ] Create test-verification.sh script
- [ ] Document manual testing steps

#### 3.5 Automation & Integration
- [ ] Complete Makefile with targets:
  - `make setup-vm` - Setup VM (if using Vagrant)
  - `make configure` - Configure CRI-O
  - `make sign` - Sign test images
  - `make test` - Run verification tests
  - `make clean` - Cleanup
- [ ] Integration with existing cosign setup
- [ ] End-to-end test

#### 3.6 Documentation
- [ ] Complete README with:
  - Architecture overview
  - CRI-O policy.json explanation
  - VM setup instructions
  - Step-by-step configuration guide
  - Troubleshooting section
  - Testing instructions
- [ ] Add diagrams and examples

**Estimated Time**: 3-4 hours (+ VM setup time by user)

---

## Phase 4: Integration & Testing ✨ FINAL

### Tasks

#### 4.1 Cross-POC Integration
- [ ] Ensure both POCs use same signing infrastructure
- [ ] Verify cosign key reuse between POCs
- [ ] Test with both Notation and Cosign signatures
- [ ] Ensure consistent behavior across runtimes

#### 4.2 Documentation Updates
- [ ] Update main README.md with runtime verification section
- [ ] Update flowcharts to include runtime verification
- [ ] Add comparison table (CRI-O vs Containerd)
- [ ] Add troubleshooting guide

#### 4.3 End-to-End Testing
- [ ] Test full flow: sign → admit → runtime verify
- [ ] Test failure scenarios
- [ ] Test with different image registries
- [ ] Performance testing (startup time impact)

#### 4.4 Polish & Cleanup
- [ ] Code review and cleanup
- [ ] Documentation review
- [ ] Add examples and screenshots
- [ ] Create demo video/script

**Estimated Time**: 2-3 hours

---

## Total Timeline

| Phase | Estimated Time | Dependencies |
|-------|---------------|--------------|
| Phase 1: Planning | 1-2 hours | None |
| Phase 2: Containerd POC | 4-5 hours | Phase 1 ✅ |
| Phase 3: CRI-O POC | 3-4 hours | Phase 1 ✅, VM |
| Phase 4: Integration | 2-3 hours | Phase 2, Phase 3 |
| **Total** | **10-14 hours** | |

---

## Parallel vs Sequential

### Option A: Sequential (Recommended)
```
Phase 1 ✅ → Phase 2 → Phase 3 → Phase 4
```
- Simpler, one thing at a time
- Can validate each POC before moving to next
- Less cognitive overhead

### Option B: Parallel (If time is critical)
```
Phase 1 ✅ → Phase 2 & Phase 3 (parallel) → Phase 4
```
- Phase 2 (Containerd) can start immediately
- Phase 3 (CRI-O) starts after VM is ready
- Requires managing two workstreams

---

## Success Metrics

### Minimum Success Criteria
- [ ] Both POCs demonstrate runtime signature verification
- [ ] Unsigned images are blocked at runtime
- [ ] Signed images pass verification
- [ ] Clear documentation for reproduction

### Ideal Success Criteria
- [ ] Above + fully automated setup
- [ ] Above + integration with existing workflows
- [ ] Above + comprehensive documentation
- [ ] Above + troubleshooting guides
- [ ] Above + performance analysis

---

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Kind + OCI hooks complexity | High | Medium | Use simpler hook, extensive testing |
| CRI-O VM setup delays | Medium | High | Start with Containerd first |
| Hook performance issues | Medium | Low | Profile and optimize |
| Policy misconfiguration | High | Medium | Provide tested examples |
| Integration conflicts | Low | Low | Reuse existing infrastructure |

---

## Resources & References

### CRI-O Resources
- [CRI-O Sigstore Tutorial](https://github.com/cri-o/cri-o/blob/main/tutorials/sigstore.md)
- [containers/image Policy Docs](https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md)
- [CRI-O Configuration](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md)

### Containerd Resources
- [OCI Runtime Spec - Hooks](https://github.com/opencontainers/runtime-spec/blob/main/config.md#posix-platform-hooks)
- [Containerd CRI Plugin](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
- [Kind Configuration](https://kind.sigs.k8s.io/docs/user/configuration/)

### Cosign Resources
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Cosign Kubernetes Integration](https://docs.sigstore.dev/cosign/kubernetes/)

---

## Next Actions

### Immediate (User Decision Required)
1. **Review this plan and approve approach**
2. **Decide implementation order**:
   - Option A: Start with Containerd (recommended, no VM needed)
   - Option B: Start with CRI-O (requires VM first)
3. **Provide VM details for CRI-O** (if choosing to do it first):
   - Platform (Vagrant/AWS/GCP/Azure/Bare metal)
   - OS preference (Ubuntu/Rocky/Fedora)
   - Access method

### Ready to Start (No blockers)
- **Containerd POC** can begin immediately with Kind
- All prerequisites are available
- Can be tested on local machine

### Blocked (Needs VM)
- **CRI-O POC** requires VM setup first
- Cannot proceed until VM is available
- Provide scripts to help with VM setup

---

## Questions for User

1. **Should we proceed with implementation?**
2. **Which POC should we start with?**
   - Containerd (Kind-based, can start now) ← Recommended
   - CRI-O (VM-based, requires VM setup first)
3. **For CRI-O POC: What VM platform will you use?**
   - This will determine which setup scripts to create
4. **Any specific requirements or constraints?**
   - Specific Kubernetes versions?
   - Specific OS versions?
   - Air-gapped scenarios?

---

## Updates Log

- **2024-XX-XX**: Plan created, Phase 1 complete ✅
- **2024-XX-XX**: Phase 2 started (to be updated)
- **2024-XX-XX**: Phase 2 complete (to be updated)
- **2024-XX-XX**: Phase 3 started (to be updated)
- **2024-XX-XX**: Phase 3 complete (to be updated)
- **2024-XX-XX**: Phase 4 complete (to be updated)

