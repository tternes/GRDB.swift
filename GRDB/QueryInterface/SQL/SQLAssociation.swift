// MARK: - SQLAssociation

/// An SQL association is a non-empty chain of steps which starts at the
/// "pivot" and ends on the "destination":
///
///     // SELECT origin.*, destination.*
///     // FROM origin
///     // JOIN pivot ON ...
///     // JOIN ...
///     // JOIN ...
///     // JOIN destination ON ...
///     Origin.including(required: association)
///
/// For direct associations such as BelongTo or HasMany, the chain contains a
/// single element, the "destination", without intermediate step:
///
///     // "Origin" belongsTo "destination":
///     // SELECT origin.*, destination.*
///     // FROM origin
///     // JOIN destination ON destination.originId = origin.id
///     let association = Origin.belongsTo(Destination.self)
///     Origin.including(required: association)
///
/// Indirect associations such as HasManyThrough have one or several
/// intermediate steps:
///
///     // "Origin" has many "destination" through "pivot":
///     // SELECT origin.*, destination.*
///     // FROM origin
///     // JOIN pivot ON pivot.originId = origin.id
///     // JOIN destination ON destination.id = pivot.destinationId
///     let association = Origin.hasMany(
///         Destination.self,
///         through: Origin.hasMany(Pivot.self),
///         via: Pivot.belongsTo(Destination.self))
///     Origin.including(required: association)
///
///     // "Origin" has many "destination" through "pivot1" and  "pivot2":
///     // SELECT origin.*, destination.*
///     // FROM origin
///     // JOIN pivot1 ON pivot1.originId = origin.id
///     // JOIN pivot2 ON pivot2.pivot1Id = pivot1.id
///     // JOIN destination ON destination.id = pivot.destinationId
///     let association = Origin.hasMany(
///         Destination.self,
///         through: Origin.hasMany(Pivot1.self),
///         via: Pivot1.hasMany(
///             Destination.self,
///             through: Pivot1.hasMany(Pivot2.self),
///             via: Pivot2.belongsTo(Destination.self)))
///     Origin.including(required: association)
///
/// :nodoc:
public /* TODO: internal */ struct SQLAssociation {
    // All steps, from pivot to destination. Never empty.
    private(set) var steps: [SQLAssociationStep]
    var keyPath: [String] { steps.map(\.keyName) }
    
    var destination: SQLAssociationStep {
        get { steps[steps.count - 1] }
        set { steps[steps.count - 1] = newValue }
    }
    
    var pivot: SQLAssociationStep {
        get { steps[0] }
        set { steps[0] = newValue }
    }
    
    init(steps: [SQLAssociationStep]) {
        assert(!steps.isEmpty)
        self.steps = steps
    }
    
    init(
        key: SQLAssociationKey,
        condition: SQLAssociationCondition,
        relation: SQLRelation,
        cardinality: SQLAssociationCardinality)
    {
        let step = SQLAssociationStep(
            key: key,
            condition: condition,
            relation: relation,
            cardinality: cardinality)
        self.init(steps: [step])
    }
    
    /// Changes the destination key
    func forDestinationKey(_ key: SQLAssociationKey) -> Self {
        with(\.destination.key, key)
    }
    
    /// Returns a new association
    func through(_ other: SQLAssociation) -> Self {
        SQLAssociation(steps: other.steps + steps)
    }
    
    func associationForFirst() -> Self {
        SQLAssociation(steps: steps.map { step in
            switch step.cardinality {
            case .toOne:
                return step
            case .toMany:
                return step.map(\.relation) { $0.with(\.firstOnly, true) }
            }
        })
    }
    
    /// Given an origin alias and rows, returns the destination of the
    /// association as a relation.
    ///
    /// This method provides support for association methods such
    /// as `request(for:)`:
    ///
    ///     struct Destination: TableRecord { }
    ///     struct Origin: TableRecord, EncodableRecord {
    ///         static let destinations = hasMany(Destination.self)
    ///         var destinations: QueryInterface<Destination> {
    ///             return request(for: Origin.destinations)
    ///         }
    ///     }
    ///
    ///     // SELECT destination.*
    ///     // FROM destination
    ///     // WHERE destination.originId = 1
    ///     let origin = Origin(id: 1)
    ///     let destinations = origin.destinations.fetchAll(db)
    ///
    /// At low-level, this gives:
    ///
    ///     let origin = Origin(id: 1)
    ///     let originAlias = TableAlias(tableName: Origin.databaseTableName)
    ///     let sqlAssociation = Origin.destination.sqlAssociation
    ///     let destinationRelation = sqlAssociation.destinationRelation(
    ///         from: originAlias,
    ///         rows: { db in try [Row(PersistenceContainer(db, origin))] })
    ///     let query = SQLQuery(relation: destinationRelation)
    ///     let generator = SQLQueryGenerator(query)
    ///     let statement, _ = try generator.prepare(db)
    ///     print(statement.sql)
    ///     // SELECT destination.*
    ///     // FROM destination
    ///     // WHERE destination.originId = 1
    ///
    /// This method works for simple direct associations such as BelongsTo or
    /// HasMany in the above examples, but also for indirect associations such
    /// as HasManyThrough, which have any number of pivot relations between the
    /// origin and the destination.
    func destinationRelation(fromOriginRows originRows: @escaping (Database) throws -> [Row]) -> SQLRelation {
        // Filter the pivot
        let pivot = self.pivot
        let filteredPivotRelation = pivot.relation.filter({ db in
            // `pivot.originId = 123` or `pivot.originId IN (1, 2, 3)`
            try pivot.condition.filteringExpression(db, leftRows: originRows(db))
        })
        
        if steps.count == 1 {
            // This is a direct join from origin to destination, without
            // intermediate step.
            //
            // SELECT destination.*
            // FROM destination
            // WHERE destination.originId = 1
            //
            // let association = Origin.hasMany(Destination.self)
            // Origin(id: 1).request(for: association)
            return filteredPivotRelation
        }
        
        // This is an indirect join from origin to destination, through
        // some intermediate steps:
        //
        // SELECT destination.*
        // FROM destination
        // JOIN pivot ON (pivot.destinationId = destination.id) AND (pivot.originId = 1)
        //
        // let association = Origin.hasMany(
        //     Destination.self,
        //     through: Origin.hasMany(Pivot.self),
        //     via: Pivot.belongsTo(Destination.self))
        // Origin(id: 1).request(for: association)
        let filteredSteps = steps.with(\.[0].relation, filteredPivotRelation)
        let reversedSteps = zip(filteredSteps, filteredSteps.dropFirst())
            .map({ (step, nextStep) -> SQLAssociationStep in
                // Intermediate steps are not selected, and including(all:)
                // children are useless:
                let relation = step.relation
                    .selectOnly([])
                    .filteringChildren({
                        switch $0.kind {
                        case .allPrefetched, .allNotPrefetched: return false
                        case .oneRequired, .oneOptional: return true
                        }
                    })
                
                // Don't interfere with user-defined keys that could be added later
                let key = step.key.map(\.baseName) { "grdb_\($0)" }
                
                return SQLAssociationStep(
                    key: key,
                    condition: nextStep.condition.reversed,
                    relation: relation,
                    cardinality: .toOne)
            })
            .reversed()
        let reversedAssociation = SQLAssociation(steps: Array(reversedSteps))
        return destination.relation.appendingChild(for: reversedAssociation, kind: .oneRequired)
    }
}

extension SQLAssociation: Refinable { }

struct SQLAssociationStep: Refinable {
    var key: SQLAssociationKey
    var condition: SQLAssociationCondition
    var relation: SQLRelation
    var cardinality: SQLAssociationCardinality
    
    var isSingular: Bool {
        switch cardinality {
        case .toOne:
            return true
        case .toMany:
            return relation.firstOnly
        }
    }
    
    var keyName: String { key.name(singular: isSingular) }
}

enum SQLAssociationCardinality {
    case toOne
    case toMany
}

// MARK: - SQLAssociationKey

/// Associations are meant to be consumed, most often into Decodable records.
///
/// Those records have singular or plural property names, and we want
/// associations to be able to fill those singular or plural names
/// automatically, so that the user does not have to perform explicit
/// decoding configuration.
///
/// Those plural or singular names are not decided when the association is
/// defined. For example, the Author.books association, which looks plural, may
/// actually generate "book" or "books" depending on the context:
///
///     struct Author: TableRecord {
///         static let books = hasMany(Book.self)
///     }
///     struct Book: TableRecord {
///     }
///
///     // "books"
///     struct AuthorInfo: FetchableRecord, Decodable {
///         var author: Author
///         var books: [Book]
///     }
///     let request = Author.including(all: Author.books)
///     let authorInfos = try AuthorInfo.fetchAll(db, request)
///
///     "book"
///     struct AuthorInfo: FetchableRecord, Decodable {
///         var author: Author
///         var book: Book
///     }
///     let request = Author.including(required: Author.books)
///     let authorInfos = try AuthorInfo.fetchAll(db, request)
///
///     "bookCount"
///     struct AuthorInfo: FetchableRecord, Decodable {
///         var author: Author
///         var bookCount: Int
///     }
///     let request = Author.annotated(with: Author.books.count)
///     let authorInfos = try AuthorInfo.fetchAll(db, request)
///
/// The SQLAssociationKey type aims at providing the necessary support for
/// those various inflections.
enum SQLAssociationKey: Refinable {
    /// A key that is inflected in singular and plural contexts.
    ///
    /// For example:
    ///
    ///     struct Author: TableRecord {
    ///         static let databaseTableName = "authors"
    ///     }
    ///     struct Book: TableRecord {
    ///         let author = belongsTo(Author.self)
    ///     }
    ///
    ///     let request = Book.including(required: Book.author)
    ///     let row = try Row.fetchOne(db, request)!
    ///     row.scopes["author"]  // singularized "authors" table name
    case inflected(String)
    
    /// A key that is inflected in plural contexts, but stricly honors
    /// user-provided name in singular contexts.
    ///
    /// For example:
    ///
    ///     struct Country: TableRecord {
    ///         let demographics = hasOne(Demographics.self, key: "demographics")
    ///     }
    ///
    ///     let request = Country.including(required: Country.demographics)
    ///     let row = try Row.fetchOne(db, request)!
    ///     row.scopes["demographics"]  // not singularized
    case fixedSingular(String)
    
    /// A key that is inflected in singular contexts, but stricly honors
    /// user-provided name in plural contexts.
    /// See .inflected and .fixedSingular for some context.
    case fixedPlural(String)
    
    /// A key that is never inflected.
    case fixed(String)
    
    var baseName: String {
        get {
            switch self {
            case let .inflected(name),
                 let .fixedSingular(name),
                 let .fixedPlural(name),
                 let .fixed(name):
                return name
            }
        }
        set {
            switch self {
            case .inflected:
                self = .inflected(newValue)
            case .fixedSingular:
                self = .fixedSingular(newValue)
            case .fixedPlural:
                self = .fixedPlural(newValue)
            case .fixed:
                self = .fixed(newValue)
            }
        }
    }
    
    func name(singular: Bool) -> String {
        if singular {
            return singularizedName
        } else {
            return pluralizedName
        }
    }
    
    var pluralizedName: String {
        switch self {
        case .inflected(let name):
            return name.pluralized
        case .fixedSingular(let name):
            return name.pluralized
        case .fixedPlural(let name):
            return name
        case .fixed(let name):
            return name
        }
    }
    
    var singularizedName: String {
        switch self {
        case .inflected(let name):
            return name.singularized
        case .fixedSingular(let name):
            return name
        case .fixedPlural(let name):
            return name.singularized
        case .fixed(let name):
            return name
        }
    }
}