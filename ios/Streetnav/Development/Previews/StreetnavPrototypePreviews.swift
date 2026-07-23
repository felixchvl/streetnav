import SwiftUI

struct StreetnavDirectionPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            QuietPrecisionHomeDirection().previewDisplayName("A - Quiet Precision")
            StreetPulseHomeDirection().previewDisplayName("B - Street Pulse")
            CompletionHuntHomeDirection().previewDisplayName("C - Completion Hunt")
            RideFocusHomeDirection().previewDisplayName("D - Ride Focus")
            NightExplorerHomeDirection().previewDisplayName("E - Night Explorer")
        }
    }
}

struct StreetnavRecommendedFlowPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(flowState: .home))
                .previewDisplayName("Recommended - Home")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(flowState: .planner))
                .previewDisplayName("Recommended - Planner")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(flowState: .routePreview))
                .previewDisplayName("Recommended - Route Preview")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(flowState: .navigating))
                .previewDisplayName("Recommended - Navigation")
            completedStreetPreview
                .previewDisplayName("Recommended - New Street Completed")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(flowState: .arrived))
                .previewDisplayName("Recommended - Arrival")
        }
    }

    @MainActor
    private static var completedStreetPreview: some View {
        let model = StreetnavPrototypeViewModel(flowState: .completedNewStreet)
        model.showsCompletionToast = true
        return StreetnavRecommendedView(model: model)
    }
}

struct StreetnavEdgeCasePreviews: PreviewProvider {
    static var previews: some View {
        Group {
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .locationDenied))
                .previewDisplayName("Edge Case - Location Denied")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .noWandrerImport))
                .previewDisplayName("Edge Case - No Wandrer Data")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .stravaDisconnected))
                .previewDisplayName("Edge Case - Strava Disconnected")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .stravaTokenExpired))
                .previewDisplayName("Edge Case - Strava Token Expired")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .preciseLocationDisabled))
                .previewDisplayName("Edge Case - Precise Location Disabled")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .weakGPS))
                .previewDisplayName("Edge Case - Weak GPS")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .offline))
                .previewDisplayName("Edge Case - Offline")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .mapDataLoading))
                .previewDisplayName("Edge Case - Map Data Loading")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .wandrerUpdating))
                .previewDisplayName("Edge Case - Wandrer Updating")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .noUntraveledNearby))
                .previewDisplayName("Edge Case - No Untraveled Streets Nearby")
        }
    }
}

struct StreetnavMoreEdgeCasePreviews: PreviewProvider {
    static var previews: some View {
        Group {
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .routeCalculationFailed))
                .previewDisplayName("Edge Case - Route Calculation Failed")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .noRouteWithinDuration))
                .previewDisplayName("Edge Case - No Route Within Duration")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .watchUnavailable))
                .previewDisplayName("Edge Case - Apple Watch Unavailable")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .vanMoofUnavailable))
                .previewDisplayName("Edge Case - VanMoof Unavailable")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .vanMoofLowBattery))
                .previewDisplayName("Edge Case - VanMoof Low Battery")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .veryLongStreetName))
                .previewDisplayName("Edge Case - Very Long Street Name")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .completedNeighborhood))
                .previewDisplayName("Edge Case - Fully Completed Neighborhood")
        }
    }
}

struct StreetnavAccessibilityAndDevicePreviews: PreviewProvider {
    static var previews: some View {
        Group {
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .largeType))
                .dynamicTypeSize(.accessibility3)
                .previewDisplayName("Accessibility - Large Type")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .smallPhone))
                .previewDevice("iPhone SE (3rd generation)")
                .previewDisplayName("Device - Small iPhone")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .largePhone))
                .previewDevice("iPhone 16 Pro Max")
                .previewDisplayName("Device - Large iPhone")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .lightMode))
                .preferredColorScheme(.light)
                .previewDisplayName("Appearance - Light")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .darkMode))
                .preferredColorScheme(.dark)
                .previewDisplayName("Appearance - Dark")
            reducedMotionPreview
                .previewDisplayName("Accessibility - Reduced Motion")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .pausedRide))
                .previewDisplayName("Recommended - Paused Ride")
            StreetnavRecommendedView(model: StreetnavPrototypeViewModel(edgeCase: .rerouting))
                .previewDisplayName("Recommended - Rerouting")
        }
    }

    @MainActor
    private static var reducedMotionPreview: some View {
        let model = StreetnavPrototypeViewModel(edgeCase: .reducedMotion)
        model.tuning.simulateReducedMotion = true
        return StreetnavRecommendedView(model: model)
    }
}

#if DEBUG
struct StreetnavTuningLabPreviews: PreviewProvider {
    static var previews: some View {
        StreetnavPrototypeTuningView()
            .previewInterfaceOrientation(.landscapeLeft)
            .previewDisplayName("Tuning Lab")
    }
}
#endif
