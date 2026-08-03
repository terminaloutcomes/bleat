import Foundation
import XCTest

@testable import BleatCore

final class AudiobookshelfAPITests: XCTestCase {
    func testBookDetailUsesNativeAccountAndMapsExpandedContract()
        async throws
    {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Self.expandedBookDetailJSON(),
                    statusCode: 200
                ),
            ]
        )

        let result = try await fixture.api.bookDetail(
            for: LibraryItemID(rawValue: "item"),
            in: LibraryID(rawValue: "library")
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(sent.url),
            resolvingAgainstBaseURL: false
        ))
        let detail = result.value

        XCTAssertEqual(
            components.path,
            "/audiobookshelf/api/items/item"
        )
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress"),
        ])
        XCTAssertEqual(
            sent.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(detail.id, LibraryItemID(rawValue: "item"))
        XCTAssertEqual(detail.libraryID, LibraryID(rawValue: "library"))
        XCTAssertEqual(detail.bookID, BookID(rawValue: "book"))
        XCTAssertEqual(detail.title, "Expanded Book")
        XCTAssertEqual(detail.subtitle, "A Subtitle")
        XCTAssertEqual(detail.authors, [
            LibraryBookContributor(
                id: AuthorID(rawValue: "author")!,
                name: "An Author"
            ),
        ])
        XCTAssertEqual(detail.narrators, ["A Narrator"])
        XCTAssertEqual(detail.series, [
            LibraryBookSeries(
                id: SeriesID(rawValue: "series")!,
                name: "A Series",
                sequence: "2"
            ),
        ])
        XCTAssertEqual(detail.genres, ["Fiction"])
        XCTAssertEqual(detail.tags, ["Favourite"])
        XCTAssertEqual(detail.descriptionPlain, "Safe description")
        XCTAssertEqual(detail.duration, 120)
        XCTAssertEqual(detail.trackCount, 1)
        XCTAssertEqual(detail.audioFileCount, 1)
        XCTAssertEqual(detail.chapters.count, 2)
        XCTAssertEqual(detail.chapters[1].title, "Second")
        XCTAssertEqual(detail.progress?.userID, UserID(rawValue: "user"))
        XCTAssertEqual(detail.progress?.bookID, BookID(rawValue: "book"))
        XCTAssertEqual(detail.progress?.currentTime, 30)
        XCTAssertEqual(detail.progress?.progress, 0.25)
        XCTAssertEqual(requests.count, 1)
    }

    func testBookDetailFailuresRemainTyped() async throws {
        let invalidCases: [(String, String)] = [
            ("\"id\": \"item\"", "\"id\": \"other\""),
            (
                "\"libraryId\": \"library\"",
                "\"libraryId\": \"other\""
            ),
            ("\"mediaType\": \"book\"", "\"mediaType\": \"podcast\""),
            (
                "\"libraryItemId\": \"item\"",
                "\"libraryItemId\": \"other\""
            ),
            ("\"userId\": \"user\"", "\"userId\": \"other\""),
            ("\"mediaItemId\": \"book\"", "\"mediaItemId\": \"other\""),
            ("\"numChapters\": 2", "\"numChapters\": 3"),
            ("\"progress\": 0.25", "\"progress\": 1.25"),
            ("\"numTracks\": 1", "\"numTracks\": 0"),
        ]
        let valid = try XCTUnwrap(String(
            data: Self.expandedBookDetailJSON(),
            encoding: .utf8
        ))

        for (target, replacement) in invalidCases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(
                        data: Data(
                            valid.replacingOccurrences(
                                of: target,
                                with: replacement
                            ).utf8
                        ),
                        statusCode: 200
                    ),
                ]
            )
            do {
                _ = try await fixture.api.bookDetail(
                    for: LibraryItemID(rawValue: "item"),
                    in: LibraryID(rawValue: "library")
                )
                XCTFail("Expected invalid expanded book detail")
            } catch {
                XCTAssertEqual(error, .invalidBookDetail)
            }
        }

        let malformed = try APIFixture(responses: [
            HTTPResponse(data: Data("{".utf8), statusCode: 200),
        ])
        do {
            _ = try await malformed.api.bookDetail(
                for: LibraryItemID(rawValue: "item"),
                in: LibraryID(rawValue: "library")
            )
            XCTFail("Expected malformed expanded book detail")
        } catch {
            XCTAssertEqual(error, .malformedResponse)
        }

        for (itemID, libraryID, expected) in [
            ("", "library", AudiobookshelfAPIError.invalidLibraryItem),
            ("item", "", AudiobookshelfAPIError.invalidLibrary),
        ] {
            let fixture = try APIFixture(responses: [])
            do {
                _ = try await fixture.api.bookDetail(
                    for: LibraryItemID(rawValue: itemID),
                    in: LibraryID(rawValue: libraryID)
                )
                XCTFail("Expected invalid request identity")
            } catch {
                XCTAssertEqual(error, expected)
            }
            let requests = await fixture.transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testHomeRequestValidationAndExactQueryContract() throws {
        for limit in [0, 101] {
            XCTAssertThrowsError(
                try LibraryHomeRequest(limit: limit)
            ) { error in
                XCTAssertEqual(
                    error as? LibraryHomeRequestError,
                    .invalidLimit
                )
            }
        }

        let request = try LibraryHomeRequest(limit: 12)
        XCTAssertEqual(request.queryItems, [
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "include", value: "progress"),
        ])

        let expandedRequest = try LibraryItemsPageRequest(
            page: 0,
            filter: LibraryItemFilter(authorID: try XCTUnwrap(
                AuthorID(rawValue: "author-1")
            )),
            collapseSeries: false,
            minified: false
        )
        XCTAssertEqual(
            expandedRequest.queryItems.first { $0.name == "minified" }?.value,
            "0"
        )
        XCTAssertEqual(
            try LibraryHomeRequest(
                limit: 8,
                includeProgress: false
            ).queryItems,
            [URLQueryItem(name: "limit", value: "8")]
        )
    }

    func testPersonalizedShelvesMapOnlyAudioBooksAndExactRoute()
        async throws
    {
        let audioBook = Self.bookItemJSON(
            id: "audio",
            libraryID: "library",
            title: "Audio Book",
            trackCount: 1
        )
        let ebook = Self.bookItemJSON(
            id: "ebook",
            libraryID: "library",
            title: "Ebook",
            trackCount: 0
        )
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        [
                          {
                            "id": "recently-added",
                            "label": "Recently Added",
                            "labelStringKey": "LabelRecentlyAdded",
                            "type": "book",
                            "entities": [\(audioBook), \(ebook)],
                            "total": 2,
                            "futureShelfField": true
                          },
                          {
                            "id": "recent-series",
                            "label": "Recent Series",
                            "type": "series",
                            "entities": [{"id": "series"}],
                            "total": 1
                          },
                          {
                            "id": "read-again",
                            "label": "Read Again",
                            "type": "book",
                            "entities": [\(ebook)],
                            "total": 1
                          }
                        ]
                        """.utf8
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibraryHomeRequest(limit: 10)

        let result = try await fixture.api.personalizedShelves(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(sent.url),
                resolvingAgainstBaseURL: false
            )
        )

        XCTAssertEqual(result.value.count, 1)
        XCTAssertEqual(result.value.first?.id, "recently-added")
        XCTAssertEqual(result.value.first?.label, "Recently Added")
        XCTAssertEqual(
            result.value.first?.labelLocalizationKey,
            "LabelRecentlyAdded"
        )
        XCTAssertEqual(result.value.first?.total, 2)
        XCTAssertEqual(result.value.first?.items.count, 1)
        XCTAssertEqual(
            result.value.first?.items.first?.id,
            LibraryItemID(rawValue: "audio")
        )
        XCTAssertEqual(
            components.path,
            "/audiobookshelf/api/libraries/library/personalized"
        )
        XCTAssertEqual(components.queryItems, request.queryItems)
        XCTAssertEqual(
            sent.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
    }

    func testPersonalizedShelfFailuresRemainTyped() async throws {
        let book = Self.bookItemJSON(
            id: "book",
            libraryID: "library",
            title: "Book",
            trackCount: 1
        )
        let cases: [Data] = [
            Data("{\"not\":\"an array\"}".utf8),
            Data(
                """
                [{
                  "id": "broken",
                  "label": "Broken",
                  "type": "book",
                  "entities": [\(book)],
                  "total": -1
                }]
                """.utf8
            ),
            Data(
                """
                [
                  {
                    "id": "duplicate",
                    "label": "First",
                    "type": "book",
                    "entities": [\(book)],
                    "total": 1
                  },
                  {
                    "id": "duplicate",
                    "label": "Second",
                    "type": "book",
                    "entities": [\(book)],
                    "total": 1
                  }
                ]
                """.utf8
            ),
        ]
        let expected: [AudiobookshelfAPIError] = [
            .malformedResponse,
            .invalidPersonalizedShelves,
            .invalidPersonalizedShelves,
        ]
        let request = try LibraryHomeRequest(limit: 1)
        for (data, expectedError) in zip(cases, expected) {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200),
                ]
            )
            do {
                _ = try await fixture.api.personalizedShelves(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                XCTFail("Expected typed personalized-shelf failure")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        let defaultRequest = try LibraryHomeRequest()
        do {
            _ = try await fixture.api.personalizedShelves(
                in: LibraryID(rawValue: ""),
                request: defaultRequest
            )
            XCTFail("Expected invalid library")
        } catch {
            XCTAssertEqual(error, .invalidLibrary)
        }
        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSearchRequestValidationAndExactQueryContract() throws {
        for query in ["", " \n ", "bad\nquery", String(repeating: "a", count: 201)] {
            XCTAssertThrowsError(
                try LibrarySearchRequest(query: query)
            ) { error in
                XCTAssertEqual(
                    error as? LibrarySearchRequestError,
                    .invalidQuery
                )
            }
        }
        for limit in [0, 101] {
            XCTAssertThrowsError(
                try LibrarySearchRequest(
                    query: "book",
                    limit: limit
                )
            ) { error in
                XCTAssertEqual(
                    error as? LibrarySearchRequestError,
                    .invalidLimit
                )
            }
        }

        let request = try LibrarySearchRequest(
            query: "  one & two  ",
            limit: 12
        )
        XCTAssertEqual(request.query, "one & two")
        XCTAssertEqual(request.queryItems, [
            URLQueryItem(name: "q", value: "one & two"),
            URLQueryItem(name: "limit", value: "12"),
        ])
    }

    func testSearchMapsExpandedBookMatchesAndExactRoute() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Self.searchJSON(
                        itemLibraryID: "library",
                        bookCount: 1
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibrarySearchRequest(
            query: "First Book",
            limit: 12
        )

        let result = try await fixture.api.search(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(sent.url),
                resolvingAgainstBaseURL: false
            )?.queryItems
        )

        XCTAssertEqual(result.value.books.count, 1)
        XCTAssertEqual(
            result.value.books.first?.id,
            LibraryItemID(rawValue: "search-item-0")
        )
        XCTAssertEqual(result.value.books.first?.title, "Search Book 0")
        XCTAssertEqual(
            result.value.books.first?.libraryID,
            LibraryID(rawValue: "library")
        )
        XCTAssertEqual(
            sent.url?.path,
            "/audiobookshelf/api/libraries/library/search"
        )
        XCTAssertEqual(queryItems, request.queryItems)
    }

    func testSearchMapsTypedAuthorAndSeriesGroups() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "book": [],
                          "authors": [{"id": "author-1", "name": "First Author"}],
                          "series": [{
                            "series": {
                              "id": "series-1",
                              "name": "First Series"
                            },
                            "books": []
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibrarySearchRequest(query: "first", limit: 5)

        let result = try await fixture.api.search(
            in: LibraryID(rawValue: "library"),
            request: request
        )

        XCTAssertEqual(result.value.books, [])
        XCTAssertEqual(
            result.value.authors,
            [
                LibrarySearchAuthorMatch(
                    id: try XCTUnwrap(AuthorID(rawValue: "author-1")),
                    name: "First Author"
                ),
            ]
        )
        XCTAssertEqual(
            result.value.series,
            [
                LibrarySearchSeriesMatch(
                    id: try XCTUnwrap(SeriesID(rawValue: "series-1")),
                    name: "First Series"
                ),
            ]
        )
    }

    func testSearchFailuresRemainTyped() async throws {
        let request = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
        let cases: [(Data, AudiobookshelfAPIError)] = [
            (
                Data("{\"authors\":[]}".utf8),
                .malformedResponse
            ),
            (
                Self.searchJSON(
                    itemLibraryID: "library",
                    bookCount: 2
                ),
                .invalidSearchResults
            ),
            (
                Self.searchJSON(
                    itemLibraryID: "other",
                    bookCount: 1
                ),
                .invalidLibraryItem
            ),
        ]
        for (data, expectedError) in cases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200),
                ]
            )
            do {
                _ = try await fixture.api.search(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                XCTFail("Expected typed search failure")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        do {
            _ = try await fixture.api.search(
                in: LibraryID(rawValue: ""),
                request: request
            )
            XCTFail("Expected invalid library")
        } catch {
            XCTAssertEqual(error, .invalidLibrary)
        }
        let sent = await fixture.transport.recordedRequests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testPageRequestValidationAndExactQueryContract() throws {
        XCTAssertThrowsError(
            try LibraryItemsPageRequest(page: -1)
        ) { error in
            XCTAssertEqual(
                error as? LibraryPageRequestError,
                .invalidPage
            )
        }
        for limit in [0, 101] {
            XCTAssertThrowsError(
                try LibraryItemsPageRequest(page: 0, limit: limit)
            ) { error in
                XCTAssertEqual(
                    error as? LibraryPageRequestError,
                    .invalidLimit
                )
            }
        }
        XCTAssertThrowsError(
            try LibraryItemFilter("bad\nfilter")
        ) { error in
            XCTAssertEqual(
                error as? LibraryPageRequestError,
                .invalidFilter
            )
        }

        let filter = try LibraryItemFilter("genres.Fiction & Fantasy")
        let request = try LibraryItemsPageRequest(
            page: 2,
            limit: 50,
            sort: .author,
            descending: true,
            filter: filter
        )
        XCTAssertEqual(request.queryItems, [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(
                name: "sort",
                value: "media.metadata.authorNameLF"
            ),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(
                name: "filter",
                value: "genres.Fiction & Fantasy"
            ),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "collapseseries", value: "1"),
            URLQueryItem(name: "include", value: "progress"),
        ])

        let sortValues = try [
            LibraryItemSort.title,
            .author,
            .addedAt,
            .updatedAt,
            .duration,
            .sequence,
        ].map {
            try LibraryItemsPageRequest(
                page: 0,
                sort: $0,
                includeProgress: false,
                collapseSeries: false
            ).queryItems
                .first { $0.name == "sort" }?
                .value
        }
        XCTAssertEqual(sortValues, [
            "media.metadata.title",
            "media.metadata.authorNameLF",
            "addedAt",
            "updatedAt",
            "media.duration",
            "sequence",
        ])
        XCTAssertEqual(
            LibraryProgressFilter.allCases.map {
                LibraryItemFilter(progress: $0).rawValue
            },
            [
                "progress.ZmluaXNoZWQ=",
                "progress.aW4tcHJvZ3Jlc3M=",
                "progress.bm90LXN0YXJ0ZWQ=",
                "progress.bm90LWZpbmlzaGVk",
            ]
        )
        XCTAssertEqual(
            LibraryItemFilter(
                authorID: try XCTUnwrap(AuthorID(rawValue: "author-1"))
            ).rawValue,
            "authors.YXV0aG9yLTE="
        )
        XCTAssertEqual(
            LibraryItemFilter(
                seriesID: try XCTUnwrap(SeriesID(rawValue: "series-1"))
            ).rawValue,
            "series.c2VyaWVzLTE="
        )
    }

    func testLibraryItemsMapsPinnedFixtureAndPagination() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: try Self.fixture(
                        named: "library-items-minified"
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibraryItemsPageRequest(
            page: 0,
            limit: 2,
            descending: true
        )

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let recordedRequests =
            await fixture.transport.recordedRequests()
        let sent = try XCTUnwrap(recordedRequests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(sent.url),
                resolvingAgainstBaseURL: false
            )?.queryItems
        )

        XCTAssertEqual(result.value.total, 3)
        XCTAssertEqual(result.value.page, 0)
        XCTAssertEqual(result.value.limit, 2)
        XCTAssertTrue(result.value.hasNextPage)
        XCTAssertEqual(result.value.items.count, 2)
        let first = result.value.items[0]
        XCTAssertEqual(first.id, LibraryItemID(rawValue: "item-one"))
        XCTAssertEqual(first.libraryID, LibraryID(rawValue: "library"))
        XCTAssertEqual(first.title, "The First Book")
        XCTAssertEqual(first.subtitle, nil)
        XCTAssertEqual(first.authorName, "First Author")
        XCTAssertEqual(first.narratorName, nil)
        XCTAssertEqual(first.seriesName, "A Series #1")
        XCTAssertEqual(first.genres, ["Fiction"])
        XCTAssertEqual(first.publisher, nil)
        XCTAssertEqual(first.publishedYear, "2024")
        XCTAssertEqual(first.duration, 7200.5)
        XCTAssertEqual(first.trackCount, 2)
        XCTAssertEqual(first.chapterCount, 4)
        XCTAssertFalse(first.isExplicit)
        XCTAssertFalse(first.isAbridged)
        XCTAssertEqual(result.value.items[1].title, "Second Book")
        XCTAssertTrue(result.value.items[1].isExplicit)
        XCTAssertTrue(result.value.items[1].isAbridged)
        XCTAssertEqual(
            sent.url?.path,
            "/audiobookshelf/api/libraries/library/items"
        )
        XCTAssertEqual(queryItems, request.queryItems)
    }

    func testLibraryItemsMapsCollapsedSeriesBrowseEntry() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "results": [{
                            "id": "item-1",
                            "libraryId": "library",
                            "addedAt": 1,
                            "updatedAt": 2,
                            "mediaType": "book",
                            "collapsedSeries": {
                              "id": "series-1",
                              "name": "A Series",
                              "numBooks": 2,
                              "seriesSequenceList": "1, 2"
                            },
                            "media": {
                              "metadata": {
                                "title": "A Series Volume One",
                                "authorName": "First Author",
                                "seriesName": "A Series #1",
                                "genres": [],
                                "explicit": false,
                                "abridged": false
                              },
                              "numTracks": 1,
                              "numChapters": 1,
                              "duration": 60
                            }
                          }],
                          "total": 1,
                          "limit": 1,
                          "page": 0
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let entry = try XCTUnwrap(result.value.browseEntries.first)
        guard case let .series(series, representative: representative) = entry else {
            return XCTFail("Expected a collapsed series browse entry")
        }
        XCTAssertEqual(
            series.id,
            try XCTUnwrap(SeriesID(rawValue: "series-1"))
        )
        XCTAssertEqual(series.name, "A Series")
        XCTAssertEqual(series.numBooks, 2)
        XCTAssertEqual(series.sequenceList, ["1, 2"])
        XCTAssertEqual(representative.id, LibraryItemID(rawValue: "item-1"))
    }

    func testSeriesFilteredExpandedPageMapsTheMatchingSequence() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "results": [{
                            "id": "item-1",
                            "libraryId": "library",
                            "addedAt": 1,
                            "updatedAt": 2,
                            "mediaType": "book",
                            "media": {
                              "metadata": {
                                "title": "A Series Volume One",
                                "authorName": "First Author",
                                "seriesName": "A Series",
                                "series": {
                                  "id": "series-1",
                                  "name": "A Series",
                                  "sequence": "1"
                                },
                                "genres": [],
                                "explicit": false,
                                "abridged": false
                              },
                              "numTracks": 1,
                              "numChapters": 1,
                              "duration": 60
                            }
                          }],
                          "total": 1,
                          "limit": 1,
                          "page": 0
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
            ]
        )
        let seriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let request = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            sort: .sequence,
            filter: LibraryItemFilter(seriesID: seriesID),
            collapseSeries: false,
            minified: false
        )

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )

        XCTAssertEqual(
            result.value.items.first?.series,
            [
                LibraryBookSeries(
                    id: seriesID,
                    name: "A Series",
                    sequence: "1"
                ),
            ]
        )
    }

    func testLibraryItemPageAndItemFailuresRemainTyped() async throws {
        let invalidCases: [(Data, AudiobookshelfAPIError)] = [
            (
                Self.pageJSON(
                    total: -1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 2,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "other"
                ),
                .invalidLibraryItem
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library",
                    mediaType: "podcast"
                ),
                .invalidLibraryItem
            ),
        ]

        for (data, expectedError) in invalidCases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200),
                ]
            )
            let request = try LibraryItemsPageRequest(
                page: 0,
                limit: 1
            )
            do {
                _ = try await fixture.api.libraryItems(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                XCTFail("Expected invalid page or item")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        let request = try LibraryItemsPageRequest(page: 0)
        do {
            _ = try await fixture.api.libraryItems(
                in: LibraryID(rawValue: ""),
                request: request
            )
            XCTFail("Expected invalid library")
        } catch {
            XCTAssertEqual(error, .invalidLibrary)
        }
        let recordedRequests =
            await fixture.transport.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testLibrariesUsesNativeAccountAndMapsForwardCompatibleDTOs()
        async throws
    {
        let response = HTTPResponse(
            data: Data(
                """
                {
                  "libraries": [
                    {
                      "id": "books",
                      "name": "Audiobooks",
                      "mediaType": "book",
                      "unknownFutureField": true
                    },
                    {
                      "id": "future",
                      "name": "Future Media",
                      "mediaType": "spoken-word-v2"
                    }
                  ],
                  "unknownEnvelopeField": 123
                }
                """.utf8
            ),
            statusCode: 200
        )
        let fixture = try APIFixture(responses: [response])

        let result = try await fixture.api.libraries()
        let requests = await fixture.transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let correlationHeader = try XCTUnwrap(
            request.value(forHTTPHeaderField: "X-Bleat-Request-ID")
        )

        XCTAssertEqual(result.value, [
            LibrarySummary(
                id: LibraryID(rawValue: "books"),
                name: "Audiobooks",
                mediaType: .book
            ),
            LibrarySummary(
                id: LibraryID(rawValue: "future"),
                name: "Future Media",
                mediaType: .unknown("spoken-word-v2")
            ),
        ])
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/libraries"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            UUID(uuidString: correlationHeader),
            result.correlationID.rawValue
        )
        XCTAssertEqual(requests.count, 1)
    }

    func testLibraryFailuresRemainTyped() async throws {
        let cases: [(HTTPResponse, AudiobookshelfAPIError)] = [
            (
                HTTPResponse(data: Data(), statusCode: 503),
                .unexpectedStatus(503)
            ),
            (
                HTTPResponse(
                    data: Data("{\"libraries\":".utf8),
                    statusCode: 200
                ),
                .malformedResponse
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "",
                            "name": "Broken",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "library",
                            "name": "   ",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
        ]

        for (response, expectedError) in cases {
            let fixture = try APIFixture(responses: [response])
            do {
                _ = try await fixture.api.libraries()
                XCTFail("Expected typed API failure")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testMissingCredentialsRemainTyped() async throws {
        let fixture = try APIFixture(
            responses: [],
            includeCredentials: false
        )

        do {
            _ = try await fixture.api.libraries()
            XCTFail("Expected missing credentials")
        } catch {
            XCTAssertEqual(
                error,
                .authentication(.missingCredentials)
            )
        }
        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationRemainsTypedAndSendsNoRequest() async throws {
        let fixture = try APIFixture(responses: [])
        let task = Task {
            try await fixture.api.libraries()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(
                error as? AudiobookshelfAPIError,
                .cancelled
            )
        }
        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private static func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first {
                $0.lastPathComponent == "\(name).json"
            }
        )
        return try Data(contentsOf: url)
    }

    private static func pageJSON(
        total: Int,
        limit: Int,
        page: Int,
        itemLibraryID: String,
        mediaType: String = "book"
    ) -> Data {
        Data(
            """
            {
              "results": [{
                "id": "item",
                "libraryId": "\(itemLibraryID)",
                "addedAt": 1,
                "updatedAt": 2,
                "mediaType": "\(mediaType)",
                "media": {
                  "metadata": {
                    "title": "Book",
                    "genres": [],
                    "explicit": false,
                    "abridged": false
                  },
                  "numTracks": 1,
                  "numChapters": 0,
                  "duration": 60
                }
              }],
              "total": \(total),
              "limit": \(limit),
              "page": \(page)
            }
            """.utf8
        )
    }

    private static func searchJSON(
        itemLibraryID: String,
        bookCount: Int
    ) -> Data {
        let matches = (0 ..< bookCount).map { index in
            """
            {
              "libraryItem": {
                "id": "search-item-\(index)",
                "libraryId": "\(itemLibraryID)",
                "addedAt": 1,
                "updatedAt": 2,
                "mediaType": "book",
                "media": {
                  "metadata": {
                    "title": "Search Book \(index)",
                    "authorName": "",
                    "narratorName": "",
                    "seriesName": "",
                    "genres": [],
                    "explicit": false,
                    "abridged": false
                  },
                  "numTracks": 1,
                  "numChapters": 0,
                  "duration": 60,
                  "futureExpandedField": true
                },
                "futureExpandedField": true
              }
            }
            """
        }.joined(separator: ",")
        return Data(
            """
            {
              "book": [\(matches)],
              "narrators": [],
              "tags": [],
              "genres": [],
              "series": [],
              "authors": [],
              "futureCategory": []
            }
            """.utf8
        )
    }

    private static func bookItemJSON(
        id: String,
        libraryID: String,
        title: String,
        trackCount: Int
    ) -> String {
        """
        {
          "id": "\(id)",
          "libraryId": "\(libraryID)",
          "addedAt": 1,
          "updatedAt": 2,
          "mediaType": "book",
          "media": {
            "metadata": {
              "title": "\(title)",
              "genres": [],
              "explicit": false,
              "abridged": false
            },
            "numTracks": \(trackCount),
            "numChapters": 0,
            "duration": 60
          }
        }
        """
    }

    private static func expandedBookDetailJSON() -> Data {
        Data(
            """
            {
              "id": "item",
              "libraryId": "library",
              "addedAt": 1000,
              "updatedAt": 2000,
              "mediaType": "book",
              "media": {
                "id": "book",
                "libraryItemId": "item",
                "metadata": {
                  "title": "Expanded Book",
                  "subtitle": "A Subtitle",
                  "authors": [{"id": "author", "name": "An Author"}],
                  "narrators": ["A Narrator"],
                  "series": [{
                    "id": "series",
                    "name": "A Series",
                    "sequence": "2"
                  }],
                  "genres": ["Fiction"],
                  "publishedYear": "2024",
                  "publishedDate": "2024-01-02",
                  "publisher": "A Publisher",
                  "description": "<p>Safe description</p>",
                  "descriptionPlain": "Safe description",
                  "isbn": "9780000000000",
                  "asin": "B000000000",
                  "language": "English",
                  "explicit": false,
                  "abridged": false,
                  "futureMetadataField": true
                },
                "tags": ["Favourite"],
                "numTracks": 1,
                "numAudioFiles": 1,
                "numChapters": 2,
                "duration": 120,
                "chapters": [
                  {"id": 0, "start": 0, "end": 60, "title": "First"},
                  {"id": 1, "start": 60, "end": 120, "title": "Second"}
                ],
                "tracks": [{
                  "index": 1,
                  "startOffset": 0,
                  "duration": 120,
                  "title": "book.m4b",
                  "contentUrl": "/api/items/item/file/inode",
                  "mimeType": "audio/mp4"
                }],
                "futureMediaField": true
              },
              "userMediaProgress": {
                "id": "progress",
                "userId": "user",
                "libraryItemId": "item",
                "episodeId": null,
                "mediaItemId": "book",
                "mediaItemType": "book",
                "duration": 120,
                "progress": 0.25,
                "currentTime": 30,
                "isFinished": false,
                "hideFromContinueListening": false,
                "ebookLocation": null,
                "ebookProgress": 0,
                "lastUpdate": 3000,
                "startedAt": 1000,
                "finishedAt": null
              },
              "futureItemField": true
            }
            """.utf8
        )
    }
}

private struct APIFixture {
    let transport: APIScriptTransport
    let api: AudiobookshelfAPI<APIScriptTransport, APICredentialStore>

    init(
        responses: [HTTPResponse],
        includeCredentials: Bool = true
    ) throws {
        transport = APIScriptTransport(responses: responses)
        let credentials = APICredentialStore(
            credentials: includeCredentials
                ? try AuthenticationTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token"
                )
                : nil
        )
        let account = try ServerAccount(
            id: AccountID(rawValue: "account"),
            server: NormalizedServerURL(
                "https://example.net/audiobookshelf"
            ),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: "user"),
                username: "reader",
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
        api = AudiobookshelfAPI(
            account: account,
            authCoordinator: AuthCoordinator(
                transport: transport,
                credentialStore: credentials
            )
        )
    }
}

private actor APICredentialStore: AccountCredentialStore {
    private var stored: AuthenticationTokens?

    init(credentials: AuthenticationTokens?) {
        stored = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        stored = nil
    }
}

private actor APIScriptTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else {
            throw APITestError.missingResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum APITestError: Error {
    case missingResponse
}
