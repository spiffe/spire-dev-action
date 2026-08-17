# Architecture Overview

## System Purpose & Scope
* A github action to make it easy to deploy spire for use in testing a users application against a working spire setup
* It should support multiple deployment architectures to map to the way the application may be used (e.g. Raw unix app, containerized kubernetes application)

## Technology Stack & Rationale
* Should at minimum, support deployment using the debs from spire-examples, and the helm charts
* Optionally support extended components such as the spire-controller-manager in static mode and spire-identity-exchange
* Keep as much of the logic as possible in bash. This will allow it to be reused later in other, similar tools, like perhaps a gitlab equivalent.
