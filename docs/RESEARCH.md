# Technical Research Notes

These notes capture external findings that informed the architecture.

## DriverWorks discovery

Control4 documents `C4:GetDevices(tFilter, locationFilter)` from OS 2.10. Passing an empty filter table returns all devices. Returned data varies by driver type and explicitly represents combo, proxy/protocol, and multi-proxy relationships.

Reference:
https://control4.github.io/docs-driverworks-api/#getdevices

Control4 documents `C4:GetProjectHierarchy()` from OS 2.10 as a table representing the location hierarchy.

Reference:
https://control4.github.io/docs-driverworks-api/#getprojecthierarchy

## Initialization

Project-wide discovery APIs should not be used during `OnDriverInit`. C4Bridge performs project discovery during `OnDriverLateInit`.

Reference:
https://control4.github.io/docs-driverworks-api/#safe-usage-of-ondriverinit-and-ondriverlateinit

## Project metadata

OS 3.0+ exposes project properties including latitude, longitude, country, city and related settings through `C4:GetProjectProperty()`; timezone is exposed through `C4:GetTimeZone()`.

Reference:
https://control4.github.io/docs-driverworks-api/

## External Director REST API

Other community projects use Director's local `/api/v1` HTTP interface. C4Bridge does **not** use it as the core architecture.

Reason:
C4Bridge already executes inside Director and can use DriverWorks directly. This avoids making the core dependent on external Director REST authentication/JWT behavior.

Projects reviewed for research only:
- https://github.com/New-Forest-Technology-Services/Control4-MCP
- https://github.com/lawtancool/pyControl4

No C4Bridge runtime dependency should be added on either project.

## Packaging

Control4 documents `.c4z` as a ZIP-based driver package containing `driver.xml`, Lua code and optional supporting directories.

Reference:
https://control4.github.io/docs-driverworks-fundamentals/

## Composer installation

Control4's documented manual-driver flow is:
**Driver → Add or Update Driver**, then locate the driver through System Design/Search and add it to the project.

Reference:
https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm
