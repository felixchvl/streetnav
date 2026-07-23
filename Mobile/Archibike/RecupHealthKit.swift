//
//  RecupHealthKit.swift
//  Archibike
//
//  Created by Félix Chevalier on 24/06/2024.
//

import CoreLocation
import Foundation
import HealthKit

class HealthKitManager {
    let healthStore = HKHealthStore()

    // Demande l'autorisation d'accéder à HealthKit
    func requestAuthorization() {
        let typesToShare: Set = [
            HKObjectType.workoutType()
        ]
        let typesToRead: Set = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            if success {
                self.startObservingWorkouts()
            } else if let error = error {
                print("HealthKit authorization error: \(error.localizedDescription)")
            }
        }
    }
    
    // Configure un observateur pour les nouveaux entraînements
    func startObservingWorkouts() {
        let sampleType = HKObjectType.workoutType()
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { query, completionHandler, error in
            if error != nil {
                // Handle error
                return
            }
            self.fetchLatestWorkouts(completion: completionHandler)
        }
        healthStore.execute(query)
    }
    
    // Récupère les nouveaux entraînements
    func fetchLatestWorkouts(completion: @escaping () -> Void) {
        let sampleType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600), end: Date(), options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: 0, sortDescriptors: [sortDescriptor]) { query, samples, error in
            guard let samples = samples as? [HKWorkout], error == nil else {
                // Handle error
                return
            }
            self.handleNewWorkouts(samples)
            completion()
        }
        healthStore.execute(query)
    }
    
    // Gère les nouveaux entraînements
    func handleNewWorkouts(_ workouts: [HKWorkout]) {
        for workout in workouts {
            // Récupère les données de localisation pour chaque entraînement
            self.fetchWorkoutRoute(for: workout)
        }
    }
    
    // Récupère les données de localisation pour un entraînement
    func fetchWorkoutRoute(for workout: HKWorkout) {
        let workoutRouteType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        
        let query = HKSampleQuery(sampleType: workoutRouteType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { query, samples, error in
            guard let samples = samples as? [HKWorkoutRoute], error == nil else {
                // Handle error
                return
            }
            
            for route in samples {
                self.fetchRouteLocations(route: route)
            }
        }
        healthStore.execute(query)
    }
    
    // Récupère les coordonnées géographiques pour une route d'entraînement
    func fetchRouteLocations(route: HKWorkoutRoute) {
        var allLocations: [CLLocation] = []
        
        let query = HKWorkoutRouteQuery(route: route) { query, locations, done, error in
            guard let locations = locations, error == nil else {
                // Handle error
                return
            }
            
            allLocations.append(contentsOf: locations)
            
            if done {
                // Traite les données de localisation
                self.handleRouteLocations(allLocations)
            }
        }
        healthStore.execute(query)
    }
    
    // Traite les données de localisation (envoie à ton app)
    func handleRouteLocations(_ locations: [CLLocation]) {
        // Convertir les coordonnées en format approprié et les synchroniser avec ton serveur/app
        for location in locations {
            print("Location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            // Envoie les données à ton application ou serveur
        }
    }
}
