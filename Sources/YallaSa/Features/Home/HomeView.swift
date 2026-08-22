import SwiftUI
import YallaSaKit

/// The home screen: where you are, what is around you, and what is leaving.
///
/// ## The change this represents
///
/// Nearby and Map used to be separate tabs. That split forced the rider to
/// choose between two halves of one question — *when is my bus* and *where is
/// it* — and to lose their place switching between them. Worse, once live
/// vehicle positions arrived, the two tabs were showing the same buses in two
/// unconnected ways: a countdown on one screen, a moving dot on the other, with
/// nothing tying them together.
///
/// They are one screen now. The map is the background, always live, and the
/// departures sit in a board that can be dragged over it. It is the layout every
/// transit app people actually like has converged on, for the good reason that
/// the two facts belong together.
///
/// The board defaults to `peek` rather than `full`: the answer is usually in the
/// first two rows, and seeing where you are while you read them is the point of
/// putting them on a map at all.
struct HomeView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationProvider

    @Environment(\.presenter) private var presenter

    @State private var snap: BottomSheet<AnyView>.Snap = .peek
    /// The planner, over the map rather than beside it in another tab.
    @State private var isPlanning = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapCanvas()
                .ignoresSafeArea()

            BottomSheet(snap: $snap) {
                AnyView(
                    VStack(spacing: 0) {
                        // Pinned above the scrolling board, not inside it: it is
                        // the one control that must be reachable at every sheet
                        // position, including the collapsed peek.
                        HomeSearchBar { isPlanning = true }
                            .padding(.horizontal, Theme.Spacing.regular)
                            .padding(.bottom, Theme.Spacing.medium)

                        NearbyBoard(
                            service: service,
                            presenter: presenter,
                            location: location,
                            // Reading the board is the moment the rider wants
                            // the whole list, so the first drag opens it rather
                            // than making them drag once to resize and again to
                            // read.
                            onScrollStart: { if snap == .peek { snap = .half } }
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $isPlanning) {
            NavigationStack {
                PlannerView(location: location)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(String(localized: "Done")) { isPlanning = false }
                        }
                    }
            }
        }
        .navigationTitle(Text("Plan"))
        .navigationBarTitleDisplayMode(.inline)
        // The map is the content here; a bar over it costs a strip of the thing
        // the screen exists to show.
        .toolbar(.hidden, for: .navigationBar)
    }
}
