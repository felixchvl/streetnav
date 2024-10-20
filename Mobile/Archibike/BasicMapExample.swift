//
//  BasicMapExample.swift
//  Archibike
//
//  Created by Félix Chevalier on 14/06/2024.
//

import Foundation

import UIKit
import MapboxMaps

final class BasicMapExample: UIViewController, ExampleProtocol {
    private var mapView: MapView!

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.ornaments.options.scaleBar.visibility = .visible

        view.addSubview(mapView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The below line is used for internal testing purposes only.
        finish()
    }
}

