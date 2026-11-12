////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import XCTest
import RealmSwift
import class Realm.Private.RLMRealmConfiguration

#if canImport(RealmSwiftTestSupport)
import RealmSwiftTestSupport
#endif

class RealmConfigurationTests: TestCase {
    func testDefaultConfiguration() {
        let defaultConfiguration = Realm.Configuration.defaultConfiguration

        XCTAssertEqual(defaultConfiguration.fileURL, try! Realm().configuration.fileURL)
        XCTAssertNil(defaultConfiguration.inMemoryIdentifier)
        XCTAssertNil(defaultConfiguration.encryptionKey)
        XCTAssertFalse(defaultConfiguration.readOnly)
        XCTAssertEqual(defaultConfiguration.schemaVersion, 0)
        XCTAssert(defaultConfiguration.migrationBlock == nil)
    }

    func testSetDefaultConfiguration() {
        let fileURL = Realm.Configuration.defaultConfiguration.fileURL
        let configuration = Realm.Configuration(fileURL: URL(fileURLWithPath: "/dev/null"))
        Realm.Configuration.defaultConfiguration = configuration
        XCTAssertEqual(Realm.Configuration.defaultConfiguration.fileURL, URL(fileURLWithPath: "/dev/null"))
        Realm.Configuration.defaultConfiguration.fileURL = fileURL
    }

    func testCannotSetMutuallyExclusiveProperties() {
        var configuration = Realm.Configuration()
        configuration.readOnly = true
        configuration.deleteRealmIfMigrationNeeded = true
        assertThrows(try! Realm(configuration: configuration),
                     reason: "Cannot set `deleteRealmIfMigrationNeeded` when `readOnly` is set.")
    }
}


class AdmissionProtectedA: Object { @objc dynamic var value = 0 }
class AdmissionProtectedB: Object { @objc dynamic var value = 0 }
class AdmissionProtectedC: Object { @objc dynamic var value = 0 }
class AdmissionWritable: Object { @objc dynamic var value = 0 }

class RealmSessionAdmissionTests: TestCase {
    private var protectedTypes: [Object.Type] {
        [AdmissionProtectedA.self, AdmissionProtectedB.self, AdmissionProtectedC.self]
    }

    private func contract(_ identifier: String = "swift-admission-tests/v1") throws -> Realm.SessionAdmission {
        try Realm.SessionAdmission(identifier: identifier, emptyObjectTypes: protectedTypes)
    }

    private func configuration(_ name: String = "admission.realm") -> Realm.Configuration {
        Realm.Configuration(fileURL: URL(fileURLWithPath: testDir).appendingPathComponent(name),
                            objectTypes: protectedTypes + [AdmissionWritable.self])
    }

    private func assertAdmissionError<T>(_ code: Int, _ body: () throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, "io.realm.session-admission", file: file, line: line)
            XCTAssertEqual((error as NSError).code, code, file: file, line: line)
        }
    }

    func testTerminalPayloadAliasesCannotEnterWriterOrLifecycleOwnership() throws {
        let manager = FileManager.default
        let target = configuration("alias-target.realm")
        let targetURL = try XCTUnwrap(target.fileURL)
        let aliasURL = URL(fileURLWithPath: testDir).appendingPathComponent("alias.realm")
        var guardedAlias = target
        guardedAlias.fileURL = aliasURL
        guardedAlias.sessionAdmission = try contract()
        try autoreleasepool {
            let ordinaryOwner = try Realm(configuration: target)
            try ordinaryOwner.write { ordinaryOwner.add(AdmissionWritable()) }
            try manager.createSymbolicLink(at: aliasURL, withDestinationURL: targetURL)
            let bytes = try Data(contentsOf: targetURL)
            let attributes = try manager.attributesOfItem(atPath: targetURL.path)
            let lockURL = targetURL.appendingPathExtension("lock")
            let lockAttributes = try manager.attributesOfItem(atPath: lockURL.path)
            assertAdmissionError(3) { try Realm(configuration: guardedAlias) }
            var callbackEntered = false
            assertAdmissionError(3) {
                try Realm.withExclusiveFileAccess(configurations: [guardedAlias]) { _ in
                    callbackEntered = true
                }
            }
            XCTAssertFalse(callbackEntered)
            XCTAssertEqual(try Data(contentsOf: targetURL), bytes)
            let after = try manager.attributesOfItem(atPath: targetURL.path)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber,
                           lockAttributes[.systemFileNumber] as? NSNumber)
            XCTAssertFalse(manager.fileExists(atPath: aliasURL.appendingPathExtension("lock").path))
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: aliasURL.path), targetURL.path)
            XCTAssertEqual(ordinaryOwner.objects(AdmissionWritable.self).count, 1)
        }
        var canonical = target
        canonical.sessionAdmission = try contract()
        try autoreleasepool {
            let admitted = try Realm(configuration: canonical)
            XCTAssertEqual(admitted.objects(AdmissionWritable.self).count, 1)
        }
        var canonicalBody = false
        try Realm.withExclusiveFileAccess(configurations: [canonical]) { _ in canonicalBody = true }
        XCTAssertTrue(canonicalBody)
        // A symlink in a parent directory shares the adjacent lock inode; it
        // is not the unsupported terminal-payload alias fixed by this guard.
        let parentAlias = URL(fileURLWithPath: testDir).appendingPathComponent("parent-alias")
        try manager.createSymbolicLink(at: parentAlias, withDestinationURL: URL(fileURLWithPath: testDir))
        var parentConfiguration = canonical
        parentConfiguration.fileURL = parentAlias.appendingPathComponent(targetURL.lastPathComponent)
        var parentBody = false
        try Realm.withExclusiveFileAccess(configurations: [parentConfiguration]) { facts in
            parentBody = true
            XCTAssertTrue(facts[0].fileExists)
        }
        XCTAssertTrue(parentBody)
        var missing = configuration("alias-control-absent.realm")
        missing.sessionAdmission = try contract()
        try Realm.withExclusiveFileAccess(configurations: [missing]) { facts in
            XCTAssertFalse(facts[0].fileExists)
        }
        try autoreleasepool { _ = try Realm(configuration: missing) }
    }

    func testEquivalentContractCanUseBindingCacheButNilAndDifferentCannot() throws {
        var config = configuration()
        config.sessionAdmission = try contract()
        let first = try Realm(configuration: config)
        var equivalent = config
        equivalent.sessionAdmission = try contract() // Independently constructed, equal value.
        XCTAssertEqual(config.sessionAdmission, equivalent.sessionAdmission)
        let cached = try Realm(configuration: equivalent)
        try cached.write { cached.add(AdmissionWritable()) }
        XCTAssertEqual(first.objects(AdmissionWritable.self).count, 1)
        var nilContract = config
        nilContract.sessionAdmission = nil
        assertAdmissionError(1) { try Realm(configuration: nilContract) }
        var different = config
        different.sessionAdmission = try contract("different-cohort/v1")
        assertAdmissionError(1) { try Realm(configuration: different) }
        XCTAssertEqual(first.objects(AdmissionWritable.self).count, 1)
    }

    func testEveryNonemptyProtectedTableRejectsBeforeMigrationOrFileEffects() throws {
        for selected in 0..<protectedTypes.count {
            let original = configuration("nonempty-\(selected).realm")
            try autoreleasepool {
                let seed = try Realm(configuration: original)
                let objects: [Object] = [AdmissionProtectedA(), AdmissionProtectedB(), AdmissionProtectedC()]
                try seed.write { seed.add(objects[selected]) }
            }
            let url = try XCTUnwrap(original.fileURL)
            let storedVersionBefore = try autoreleasepool { try schemaVersionAtURL(url) }
            XCTAssertEqual(storedVersionBefore, 0)
            let before = try Data(contentsOf: url)
            let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
            let inodeBefore = attributesBefore[.systemFileNumber] as? NSNumber
            let modifiedBefore = attributesBefore[.modificationDate] as? Date
            XCTAssertNotNil(inodeBefore)
            XCTAssertNotNil(modifiedBefore)
            var migrated = original
            migrated.schemaVersion = 1
            migrated.objectTypes = [AdmissionWritable.self] // A successful migration would remove legacy tables.
            migrated.sessionAdmission = try contract()
            let migrationRan = Locked(false)
            migrated.migrationBlock = { _, _ in migrationRan.value = true }
            assertAdmissionError(6) { try Realm(configuration: migrated) }
            XCTAssertFalse(migrationRan.value)
            XCTAssertEqual(try Data(contentsOf: url), before)
            let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributesAfter[.systemFileNumber] as? NSNumber, inodeBefore)
            XCTAssertEqual(attributesAfter[.modificationDate] as? Date, modifiedBefore)
            XCTAssertEqual(try autoreleasepool { try schemaVersionAtURL(url) }, storedVersionBefore)
            try autoreleasepool {
                let unchanged = try Realm(configuration: original)
                XCTAssertEqual(unchanged.configuration.schemaVersion, 0)
                let counts = [unchanged.objects(AdmissionProtectedA.self).count,
                              unchanged.objects(AdmissionProtectedB.self).count,
                              unchanged.objects(AdmissionProtectedC.self).count]
                XCTAssertEqual(counts, (0..<3).map { $0 == selected ? 1 : 0 })
            }
        }
    }

    func testExclusiveAccessKeepsActualLockThroughBodyAndPreservesItsInode() throws {
        var config = configuration()
        config.sessionAdmission = try contract()
        try autoreleasepool { _ = try Realm(configuration: config) }
        let lockURL = try XCTUnwrap(config.fileURL).appendingPathExtension("lock")
        var inode: NSNumber?
        var bodyRan = false
        try Realm.withExclusiveFileAccess(configurations: [config]) { facts in
            bodyRan = true
            XCTAssertEqual(facts.count, 1)
            XCTAssertTrue(facts[0].fileExists)
            inode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
            XCTAssertNotNil(inode)
            var nestedRan = false
            assertAdmissionError(7) {
                try Realm.withExclusiveFileAccess(configurations: [config]) { _ in nestedRan = true }
            }
            XCTAssertFalse(nestedRan)
        }
        XCTAssertTrue(bodyRan)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber, inode)
        try Realm.withExclusiveFileAccess(configurations: [config]) { _ in }
    }

    func testThrowingExclusiveBodyReleasesEveryAcquiredLock() throws {
        enum BodyFailure: Error { case expected }
        var first = configuration("first.realm")
        first.sessionAdmission = try contract()
        var second = configuration("second.realm")
        second.sessionAdmission = try contract()
        var bodyRan = false
        XCTAssertThrowsError(try Realm.withExclusiveFileAccess(configurations: [second, first]) { facts in
            bodyRan = true
            XCTAssertEqual(facts.count, 2)
            XCTAssertTrue(facts.allSatisfy { !$0.fileExists })
            throw BodyFailure.expected
        }) { error in XCTAssertTrue(error is BodyFailure) }
        XCTAssertTrue(bodyRan)
        try Realm.withExclusiveFileAccess(configurations: [first, second]) { facts in
            XCTAssertEqual(facts.count, 2)
        }
    }

    func testLiveWriterPreventsExclusiveBody() throws {
        var config = configuration()
        config.sessionAdmission = try contract()
        let writer = try Realm(configuration: config)
        var bodyRan = false
        assertAdmissionError(7) {
            try Realm.withExclusiveFileAccess(configurations: [config]) { _ in bodyRan = true }
        }
        XCTAssertFalse(bodyRan)
        try writer.write { writer.add(AdmissionWritable()) }
        XCTAssertEqual(writer.objects(AdmissionWritable.self).count, 1)
    }
}


extension RealmSessionAdmissionTests {
    func testIdentifierBoundsAndLengthPreservingEmbeddedNulRejection() throws {
        XCTAssertEqual(try contract(String(repeating: "a", count: 256)).identifier.count, 256)
        for identifier in ["", String(repeating: "a", count: 257), "valid\u{0}suffix"] {
            assertAdmissionError(2) { try contract(identifier) }
        }
        // UTF-8 bytes, rather than NSString's UTF-16 length, define the identifier bound.
        assertAdmissionError(2) { try contract(String(repeating: "あ", count: 86)) }
    }

    func testConfigurationEqualityIncludesFullAdmissionIdentity() throws {
        var first = configuration()
        var equivalent = first
        first.sessionAdmission = try contract()
        XCTAssertNotEqual(first, equivalent)
        equivalent.sessionAdmission = try contract()
        XCTAssertEqual(first, equivalent)
        equivalent.sessionAdmission = try contract("different-cohort/v1")
        XCTAssertNotEqual(first, equivalent)
        var descriptorMismatch = first
        descriptorMismatch.sessionAdmission = try Realm.SessionAdmission(
            identifier: "swift-admission-tests/v1", emptyObjectTypes: [AdmissionProtectedA.self])
        XCTAssertNotEqual(first, descriptorMismatch)
    }
}


extension RealmSessionAdmissionTests {
    func testFrozenBindingRetainsAdmissionAcrossMatchingBackgroundOpen() throws {
        var configured = configuration("frozen-binding.realm")
        configured.sessionAdmission = try contract()
        let admitted = configured
        let frozen: Realm = try autoreleasepool {
            let live = try Realm(configuration: admitted)
            return live.freeze()
        }
        XCTAssertTrue(frozen.isFrozen)
        XCTAssertEqual(frozen.objects(AdmissionWritable.self).count, 0)
        dispatchSyncNewThread {
            do {
                let matching = try Realm(configuration: admitted)
                var nilContract = admitted
                nilContract.sessionAdmission = nil
                XCTAssertThrowsError(try Realm(configuration: nilContract)) { error in
                    XCTAssertEqual((error as NSError).domain, "io.realm.session-admission")
                    XCTAssertEqual((error as NSError).code, 1)
                }
                var different = admitted
                different.sessionAdmission = try Realm.SessionAdmission(identifier: "other-background-cohort/v1",
                    emptyObjectTypes: [AdmissionProtectedA.self, AdmissionProtectedB.self, AdmissionProtectedC.self])
                XCTAssertThrowsError(try Realm(configuration: different)) { error in
                    XCTAssertEqual((error as NSError).domain, "io.realm.session-admission")
                    XCTAssertEqual((error as NSError).code, 1)
                }
                try matching.write { matching.add(AdmissionWritable()) }
            } catch { XCTFail("Matching background admitted open failed: \(error)") }
        }
        // The background live Realm is gone; the old frozen snapshot still holds the DB capability.
        XCTAssertEqual(frozen.objects(AdmissionWritable.self).count, 0)
        var nilContract = admitted
        nilContract.sessionAdmission = nil
        assertAdmissionError(1) { try Realm(configuration: nilContract) }
        var different = admitted
        different.sessionAdmission = try contract("other-main-cohort/v1")
        assertAdmissionError(1) { try Realm(configuration: different) }
        let matching = try Realm(configuration: admitted)
        XCTAssertEqual(matching.objects(AdmissionWritable.self).count, 1)
    }
}


extension RealmSessionAdmissionTests {
    func testOrdinaryAliasCannotBypassLiveAdmittedOwnerOrGenericLifecycle() throws {
        let manager = FileManager.default
        var canonical = configuration("inverse-alias-target.realm")
        canonical.sessionAdmission = try contract()
        let targetURL = try XCTUnwrap(canonical.fileURL)
        let aliasURL = URL(fileURLWithPath: testDir).appendingPathComponent("inverse-alias.realm")
        let lockURL = targetURL.appendingPathExtension("lock")
        var ordinaryAlias = canonical
        ordinaryAlias.fileURL = aliasURL
        ordinaryAlias.sessionAdmission = nil
        let canonicalLockInode: NSNumber? = try autoreleasepool {
            let owner = try Realm(configuration: canonical)
            try owner.write { owner.add(AdmissionWritable()) }
            try manager.createSymbolicLink(at: aliasURL, withDestinationURL: targetURL)
            let bytes = try Data(contentsOf: targetURL)
            let attributes = try manager.attributesOfItem(atPath: targetURL.path)
            let lockBytes = try Data(contentsOf: lockURL)
            let lockInode = try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
            XCTAssertNotNil(lockInode)
            assertAdmissionError(3) { try Realm(configuration: ordinaryAlias) }
            var guardedAlias = ordinaryAlias
            guardedAlias.sessionAdmission = try contract()
            assertAdmissionError(3) { try Realm(configuration: guardedAlias) }
            var seededAlias = ordinaryAlias
            seededAlias.seedFilePath = targetURL
            assertAdmissionError(3) { try Realm(configuration: seededAlias) }
            var migratedAlias = ordinaryAlias
            migratedAlias.schemaVersion = 1
            let migrated = Locked(false)
            migratedAlias.migrationBlock = { _, _ in migrated.value = true }
            assertAdmissionError(3) { try Realm(configuration: migratedAlias) }
            XCTAssertFalse(migrated.value)
            assertAdmissionError(3) { try Realm.deleteFiles(for: ordinaryAlias) }
            assertAdmissionError(3) { try Realm.deleteFiles(for: guardedAlias) }
            assertAdmissionError(3) { try owner.writeCopy(toFile: aliasURL) }
            assertAdmissionError(3) { try owner.writeCopy(configuration: ordinaryAlias) }
            var ordinaryCanonical = canonical
            ordinaryCanonical.sessionAdmission = nil
            assertAdmissionError(1) { try Realm(configuration: ordinaryCanonical) }
            XCTAssertThrowsError(try Realm.deleteFiles(for: ordinaryCanonical))
            XCTAssertEqual(try Data(contentsOf: targetURL), bytes)
            let after = try manager.attributesOfItem(atPath: targetURL.path)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(try Data(contentsOf: lockURL), lockBytes)
            XCTAssertEqual(try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber, lockInode)
            XCTAssertFalse(manager.fileExists(atPath: aliasURL.appendingPathExtension("lock").path))
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: aliasURL.path), targetURL.path)
            XCTAssertEqual(owner.objects(AdmissionWritable.self).count, 1)
            return lockInode
        }
        // The generic public deletion path uses exclusive lifecycle ownership,
        // consumes only the payload/sidecars, and retains the coordination inode.
        var ordinaryCanonical = canonical
        ordinaryCanonical.sessionAdmission = nil
        XCTAssertTrue(try Realm.deleteFiles(for: ordinaryCanonical))
        XCTAssertFalse(manager.fileExists(atPath: targetURL.path))
        XCTAssertEqual(try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber,
                       canonicalLockInode)
    }

    func testBindingCacheRevalidatesTerminalPayloadBeforeReturningWriter() throws {
        let manager = FileManager.default
        for admitted in [false, true] {
            var configured = configuration("cache-alias-\(admitted).realm")
            if admitted { configured.sessionAdmission = try contract() }
            let url = try XCTUnwrap(configured.fileURL)
            let movedURL = URL(fileURLWithPath: testDir).appendingPathComponent("cache-moved-\(admitted).realm")
            try autoreleasepool {
                let owner = try Realm(configuration: configured)
                let inode = try manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
                let lockURL = url.appendingPathExtension("lock")
                let lockInode = try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber
                // Deliberate fixture mutation makes the existing binding cache
                // reachable. It does not assert arbitrary replacement is serialized.
                try manager.moveItem(at: url, to: movedURL)
                do {
                    defer {
                        do {
                            if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                                try manager.removeItem(at: url)
                            }
                            try manager.moveItem(at: movedURL, to: url)
                        } catch { XCTFail("Could not restore cache alias fixture: \(error)") }
                    }
                    try manager.createSymbolicLink(at: url, withDestinationURL: movedURL)
                    assertAdmissionError(3) { try Realm(configuration: configured) }
                    assertAdmissionError(3) { try Realm.deleteFiles(for: configured) }
                    XCTAssertEqual(try manager.attributesOfItem(atPath: lockURL.path)[.systemFileNumber] as? NSNumber,
                                   lockInode)
                }
                XCTAssertEqual(try manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
                try owner.write { owner.add(AdmissionWritable()) }
                XCTAssertEqual(owner.objects(AdmissionWritable.self).count, 1)
            }
        }
    }
}
