/*
 * Copyright (c) 2026 European Commission
 *
 * Licensed under the EUPL, Version 1.2 or - as soon they will be approved by the European
 * Commission - subsequent versions of the EUPL (the "Licence"); You may not use this work
 * except in compliance with the Licence.
 *
 * You may obtain a copy of the Licence at:
 * https://joinup.ec.europa.eu/software/page/eupl
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF
 * ANY KIND, either express or implied. See the Licence for the specific language
 * governing permissions and limitations under the Licence.
 */
import SwiftData
import Foundation

protocol SwiftDataService: Actor {
  func write<T: PersistentModel & IdentifiableObject>(_ object: T) throws
  func writeAll<T: PersistentModel & IdentifiableObject>(_ objects: [T]) throws
  func read<T: PersistentModel & IdentifiableObject, R>(predicate: Predicate<T>, map: (T) -> R) throws -> R?
  func readAll<T: PersistentModel & IdentifiableObject, R>(_ type: T.Type, map: (T) -> R) throws -> [R]
  func delete<T: PersistentModel & IdentifiableObject>(predicate: Predicate<T>) throws
  func deleteAll<T: PersistentModel & IdentifiableObject>(of type: T.Type) throws
}

final actor SwiftDataServiceImpl: SwiftDataService, ModelActor {

  nonisolated let modelContainer: ModelContainer
  nonisolated let modelExecutor: any ModelExecutor

  init(storageConfig: StorageConfig) {
    do {
      let container = try ModelContainer(
        for: storageConfig.schemas,
        configurations: storageConfig.modelConfiguration
      )
      let context = ModelContext(container)
      self.modelContainer = container
      self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    } catch {
      fatalError("ModelContainer init failed: \(error)")
    }
  }

  func write<T: PersistentModel & IdentifiableObject>(_ object: T) throws {
    modelContext.insert(object)
    try modelContext.save()
  }

  func writeAll<T: PersistentModel & IdentifiableObject>(_ objects: [T]) throws {
    for object in objects { modelContext.insert(object) }
    try modelContext.save()
  }

  func read<T: PersistentModel & IdentifiableObject, R>(predicate: Predicate<T>, map: (T) -> R) throws -> R? {
    var fd = FetchDescriptor<T>(predicate: predicate)
    fd.fetchLimit = 1
    return try modelContext.fetch(fd).first.map(map)
  }

  func readAll<T: PersistentModel & IdentifiableObject, R>(_ type: T.Type, map: (T) -> R) throws -> [R] {
    try modelContext.fetch(FetchDescriptor<T>()).map(map)
  }

  func delete<T: PersistentModel & IdentifiableObject>(predicate: Predicate<T>) throws {
    var fd = FetchDescriptor<T>(predicate: predicate)
    fd.fetchLimit = 1
    if let object = try modelContext.fetch(fd).first {
      modelContext.delete(object)
      try modelContext.save()
    }
  }

  func deleteAll<T: PersistentModel & IdentifiableObject>(of type: T.Type) throws {
    let results = try modelContext.fetch(FetchDescriptor<T>())
    for result in results { modelContext.delete(result) }
    if !results.isEmpty { try modelContext.save() }
  }
}
