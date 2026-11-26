README — MATLAB–ZOS-API Automated Optical Optimization
====================================================

1. Overview
-----------
MATLABStandaloneApplication1.m contains custom MATLAB code for parameterized
optical-system optimization and RMS spot-radius extraction using the Zemax
OpticStudio application programming interface (ZOS-API).

The script does not create or include any test optical model. Users must supply
an existing, compatible OpticStudio sequential model (.zmx or .zos).

2. Requirements
---------------
- Windows operating system.
- MATLAB with compatible .NET support.
- A licensed installation of Zemax OpticStudio with ZOS-API access.
- An existing OpticStudio model compatible with the script's surface numbering,
  merit-function operands, optimization settings, and Binary 2 surface parameters.

3. Configure paths and run
--------------------------
Save MATLABStandaloneApplication1.m in a MATLAB-accessible folder. In MATLAB,
provide the full path to your own optical model and, optionally, an output folder:

    args = struct();
    args.modelFile = 'D:\YourProject\Optical_Model.zmx';
    args.outputDir = 'D:\YourProject\Results';
    results = MATLABStandaloneApplication1(args);

Replace the example paths with paths that exist on your computer. An .zos
model may also be used if it is compatible with the script.

The args.modelFile field is REQUIRED. The script will raise an error if it
is missing or points to a nonexistent file. No default model or test file is
loaded. The args.outputDir field is OPTIONAL; when omitted, output is written
to a 'results' subfolder alongside MATLABStandaloneApplication1.m.

4. Workflow
-----------
The script:
- Connects to OpticStudio in ZOS-API Standalone mode.
- Sweeps entrance-pupil diameter D and F-number according to the D_list and
  F_lists defined in the source code.
- Sets focal length and five configured field positions for each design.
- Generates merit-function operands and physical design constraints.
- Runs local and Hammer optimization, then a progressive constrained search.
- Extracts RMS spot radii at the five configured fields and saves model files.

Optical surface numbers, phase limits, normalization parameters, and other
settings are specific to the supplied optical-system model. Review these
settings before running the script on another model.

5. Outputs
----------
Within the selected output directory, the script creates:
- Optimization_Results.mat: a MATLAB variable named results_data, with columns:
    1  Entrance pupil diameter D (mm)
    2  F-number
    3  Full field of view (degrees)
    4  RMS spot radius at field 1 (on-axis)
    5  RMS spot radius at field 2 (0.707 × half-field)
    6  RMS spot radius at field 3 (half-field)
    7  RMS spot radius at field 4 (1-degree field)
    8  RMS spot radius at field 5 (2-degree field)
  RMS values retain the native units returned by OpticStudio/ZOS-API; verify
  the model units before converting or comparing results.
- Saved_Models/: optimized optical-system files for sampled design points.
- Task_*_MaxValidRatio.zmx: intermediate valid-state snapshots where produced.

6. Reproducibility notes
------------------------
- No optical-system model is bundled with this source file.
- Running the script requires compatible commercial software and licenses.
- The supplied code is the automated design/optimization and data-extraction
  component; it does not by itself contain all subsequent fitting, GD resource
  analysis, or achievable-design-boundary plotting procedures.
- Source-code cleanup removed inactive commented-out alternatives and retained
  useful procedural comments.

7. Files for sharing
--------------------
    MATLABStandaloneApplication.m
    README_ZOSAPI_Code.txt
