import Foundation
import Testing
@testable import Agencil

/// U25 review round 2, finding 1 (docs/U25-SPEC.md section 4): editing the harness or the model after a preset
/// fill drops the preset's vendor, plan and hosted flag, so the config infers them from what the owner chose.
@Suite(.serialized) @MainActor struct U25R2SeatFormTests {
    private func filled() -> SettingsStore {
        let store = SettingsStore.demo()
        store.applyPreset("glm-free")
        return store
    }

    @Test func presetFillCarriesVendorPlanAndHosted() {
        let form = filled().seatForm
        #expect(form.vendor == "zhipu")
        #expect(form.plan == "free")
        #expect(form.hosted == true)
        #expect(form.harness == "opencode")
        #expect(form.model == "opencode/glm-5.3-flash-free")
    }

    @Test func editingTheModelDropsPresetDerivedFields() {
        let store = filled()
        store.seatForm.model = "opencode/some-paid-model"
        #expect(store.seatForm.vendor.isEmpty)
        #expect(store.seatForm.plan.isEmpty)
        #expect(store.seatForm.hosted == nil)
        #expect(store.seatForm.model == "opencode/some-paid-model")
    }

    @Test func editingTheHarnessDropsPresetDerivedFields() {
        let store = filled()
        store.seatForm.harness = "claude"
        #expect(store.seatForm.vendor.isEmpty)
        #expect(store.seatForm.plan.isEmpty)
        #expect(store.seatForm.hosted == nil)
        #expect(store.seatForm.harness == "claude")
    }

    @Test func editingOtherFieldsKeepsPresetDerivedFields() {
        let store = filled()
        store.seatForm.name = "my-glm"
        store.seatForm.cap = "900"
        store.seatForm.endpoint = ""
        #expect(store.seatForm.vendor == "zhipu")
        #expect(store.seatForm.plan == "free")
        #expect(store.seatForm.hosted == true)
    }

    @Test func writingTheSameModelBackIsNotAnEdit() {
        let store = filled()
        store.seatForm.model = store.seatForm.model
        store.seatForm.harness = store.seatForm.harness
        #expect(store.seatForm.vendor == "zhipu")
        #expect(store.seatForm.plan == "free")
    }
}
