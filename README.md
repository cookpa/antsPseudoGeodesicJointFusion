# antsPseudoGeodesicJointFusion

Script to do joint label fusion (JLF) by using an intermediate template to warp a collection of atlases to the target image. This will be less accurate than independently registering all the atlases to every target image, but much faster. 

Optionally, do majority voting as well or instead of JLF.

See the usage for `antsJointFusion` for information on the JLF algorithm, including citations.


## Prerequisites

Once per template:

 - Register all atlases to the template. Organize atlases, segmentations and warps in the format described in the usage.

For each target image:

 - Register to the template.


## Example call

```
export ANTSPATH=/path/to/ants/

inputRoot=myImage

scripts/pseudoGeodesicJointFusion.pl \
  --input-image ${inputRoot}.nii.gz \
  --input-mask ${inputRoot}_Mask.nii.gz \
  --template-to-subject-warp-string "-t [ ${inputRoot}_ToTemplate_0GenericAffine.mat, 1 ] -t ${inputRoot}_ToTemplate_1InverseWarp.nii.gz" \
  --atlas-dir /path/to/myAtlasesRegisteredToTemplate \
  --output-root /path/to/Output/${inputRoot}
```

See usage for other options.
