import Foundation
import Testing
@testable import Collectly

struct AlbumCollectionTests {
    @Test func createTrimsName() throws {
        var collection = AlbumCollection()
        let album = try collection.create(named: "  Vacation \n")
        #expect(album.name == "Vacation")
        #expect(collection.albums == [album])
    }

    @Test func rejectsInvalidNames() throws {
        var collection = AlbumCollection()
        try collection.create(named: "Family")

        #expect(throws: AlbumError.emptyName) { try collection.create(named: "   ") }
        #expect(throws: AlbumError.duplicateName("family")) { try collection.create(named: "family") }
        let longName = String(repeating: "x", count: AlbumCollection.maxNameLength + 1)
        #expect(throws: AlbumError.nameTooLong(limit: AlbumCollection.maxNameLength)) {
            try collection.create(named: longName)
        }
        #expect(collection.albums.count == 1)
    }

    @Test func renameAllowsSameNameForSameAlbumButNotClashes() throws {
        var collection = AlbumCollection()
        let family = try collection.create(named: "Family")
        try collection.create(named: "Pets")

        try collection.rename(family.id, to: "FAMILY")
        #expect(collection.album(id: family.id)?.name == "FAMILY")
        #expect(throws: AlbumError.duplicateName("pets")) { try collection.rename(family.id, to: "pets") }
        #expect(throws: AlbumError.notFound) { try collection.rename(UUID(), to: "Other") }
    }

    @Test func addIsIdempotentAndRemoveWorks() throws {
        var collection = AlbumCollection()
        let album = try collection.create(named: "Pets")

        #expect(try collection.add("p1", to: album.id))
        #expect(try !collection.add("p1", to: album.id))
        try collection.add("p2", to: album.id)
        #expect(collection.album(id: album.id)?.photoIDs == ["p1", "p2"])
        #expect(collection.albums(containing: "p1").map(\.id) == [album.id])

        collection.remove("p1", from: album.id)
        #expect(collection.album(id: album.id)?.photoIDs == ["p2"])
        #expect(throws: AlbumError.notFound) { try collection.add("p3", to: UUID()) }
    }

    @Test func removePhotosEverywhereAndDelete() throws {
        var collection = AlbumCollection()
        let a = try collection.create(named: "A")
        let b = try collection.create(named: "B")
        try collection.add("p1", to: a.id)
        try collection.add("p1", to: b.id)
        try collection.add("p2", to: b.id)

        collection.removePhotosEverywhere(["p1"])
        #expect(collection.albums(containing: "p1").isEmpty)
        #expect(collection.album(id: b.id)?.photoIDs == ["p2"])

        collection.delete(a.id)
        #expect(collection.albums.map(\.id) == [b.id])
    }
}
