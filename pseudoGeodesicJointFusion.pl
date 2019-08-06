#!/usr/bin/perl -w
#
#

use strict;

# Nicer implementation than File::Path
use Cwd 'abs_path';
use FindBin qw($Bin);
use File::Path;
use File::Spec;
use File::Basename;
use Getopt::Long;

# Get env vars
my ($antsPath, $sysTmpDir) = @ENV{'ANTSPATH', 'TMPDIR'};

if (!$antsPath || ! -f "${antsPath}antsRegistration") {
    die("Script requires ANTSPATH to be defined");
}

# Variables with defaults
my $outputMajorityVote = 0;
my $outputJLF = 1;
my $jlfMajorityThresh = 0.9;
my $atlasLabelInterp = "GenericLabel";

my $usage = qq{

  Joint fusion of atlases via a template

  $0 
     --input-image
     --template-to-subject-warp-prefix
     --atlas-dir
     --output-root
     [options]


  The algorithm applies the N warps from the atlases to the template concatenated with the single 
  template to subject warp.

  [atlas1] -> [template] 
  [atlas2] -> [template]  -> [subject]
  [atlas3] -> [template]

  Joint label fusion (JLF) is then run on the atlases and labels in the subject space.

  The atlases should be organized in a single directory containing for each atlas:
  
    atlas.nii.gz
    atlas_Seg.nii.gz
    atlas_ToTemplate1Warp.nii.gz
    atlas_ToTemplate0GenericAffine.mat


  Required args:

    --input-image
      Head or brain image to be labeled. 

    --template-to-subject-warp-string
      A string passed to antsApplyTransforms to warp the template to the subject.
       
    --atlas-dir
      Directory containing atlases, segmentations, and warps to the template.

    --output-root
      Root for output images.


  Options:

    --input-mask
      A mask in which labeling is performed. If not provided, it is defined from the atlas 
      segmentations.

    --majority-vote
      Do majority voting, less accurate but much faster than JLF (default = $outputMajorityVote). 

    --jlf
      Do joint label fusion (default = $outputJLF). 

    --jlf-majority-thresh
      Voting threshold for computing JLF in each voxel. For each voxel, the proportion of 
      atlases agreeing on the label is computed. If agreement between atlases is equal or greater 
      than the threshold, joint fusion is not computed in the voxel (default = $jlfMajorityThresh).

    --atlas-label-interpolation
      Method to resample the individual atlas labels in subject space, before voting or label fusion
      (default = $atlasLabelInterp).


  Output:

   Majority voting labels or JLF, or both.

    
  Requires ANTs

};


if ($#ARGV < 0) {
    print $usage;
    exit 1;
}

my ($inputImage, $templateToSubjectWarpString, $atlasDir, $outputRoot);

my $inputMask = "";

GetOptions ("input-image=s" => \$inputImage,
	    "input-mask=s" => \$inputMask,  
	    "template-to-subject-warp-string=s" => \$templateToSubjectWarpString,
	    "atlas-dir=s" => \$atlasDir,
	    "output-root=s" => \$outputRoot,
	    "atlas-label-interpolation=s" => \$atlasLabelInterp,
	    "jlf-majority-thresh=f" => \$jlfMajorityThresh,
	    "majority-vote=i" => \$outputMajorityVote,
	    "jlf=i" => \$outputJLF

    )
    or die("Error in command line arguments\n");


my ($outputFileRoot,$outputDir) = fileparse($outputRoot);

if (! -d $outputDir ) { 
    mkpath($outputDir, {verbose => 0}) or die "Cannot create output directory $outputDir\n\t";
}

# Set to 1 to delete intermediate files after we're done
my $cleanup=1;

# Directory for temporary files that is deleted later if $cleanup
my $tmpDir = "";

my $tmpDirBaseName = "${outputFileRoot}pseudoJLF";

if ( !($sysTmpDir && -d $sysTmpDir) ) {
    $tmpDir = $outputDir . "/${tmpDirBaseName}";
}
else {
    # Have system tmp dir
    $tmpDir = $sysTmpDir . "/${tmpDirBaseName}";
}

# Gets removed later, so check we can create this and if not, exit immediately
mkpath($tmpDir, {verbose => 0, mode => 0755}) or die "Cannot create working directory $tmpDir (maybe it exists from a previous failed run)\n\t";

# These exist in the tmp dir because they are read several times
my $refImage="${tmpDir}/${outputFileRoot}ImageToLabel.nii.gz";
my $refMask = "${tmpDir}/${outputFileRoot}Mask.nii.gz";

system("cp $inputImage $refImage");

if (-f $inputMask) {
    system("cp $inputMask $refMask");
}

# Assume atlases of the form ${id}.nii.gz ${id}_seg.nii.gz

my @atlasSegImages = glob("${atlasDir}/*_Seg.nii.gz");

my @atlasSubjects = map { m/${atlasDir}\/?(.*)_Seg\.nii\.gz$/; $1 } @atlasSegImages;


# Populated as we deform the images to subject space
my @grayImagesSubjSpace = ();
my @segImagesSubjSpace = ();

foreach my $atlasSubj (@atlasSubjects) {

    # Warp atlas brains and labels to subject space

    my $grayImage = "${atlasDir}/${atlasSubj}.nii.gz";

    # This is just here to enable leave one out validation
    if ($grayImage eq $inputImage) {
	print " Skipping $atlasSubj because it is the same image as the input \n";
	next;
    }

    my $segImage = "${atlasDir}/${atlasSubj}_Seg.nii.gz";
    
    my $grayToTemplateWarp = "${atlasDir}/${atlasSubj}_ToTemplate_1Warp.nii.gz";
    
    my $grayToTemplateAffine = "${atlasDir}/${atlasSubj}_ToTemplate_0GenericAffine.mat";
    
    my $warpString = "-r $refImage $templateToSubjectWarpString -t $grayToTemplateWarp -t $grayToTemplateAffine ";

    my $grayImageDeformed = "${tmpDir}/${atlasSubj}_Deformed.nii.gz";

    my $segImageDeformed = "${tmpDir}/${atlasSubj}_SegDeformed.nii.gz";

    print "  Warping $atlasSubj \n";

    my $aatCmd = "${antsPath}antsApplyTransforms -d 3 -i $grayImage -o $grayImageDeformed $warpString";

    print "$aatCmd\n";

    system("$aatCmd");

    $aatCmd = "${antsPath}antsApplyTransforms -d 3 -i $segImage -o $segImageDeformed -n $atlasLabelInterp $warpString";

    print "$aatCmd\n";

    system("$aatCmd");

    push(@grayImagesSubjSpace, $grayImageDeformed);
    push(@segImagesSubjSpace, $segImageDeformed);

}

if (! -f $refMask) {

    # No user supplied mask, create one from the union of all atlas masks
    
    my $numAtlases = scalar(@segImagesSubjSpace);
    
    print "\n No brain mask defined, creating mask from binarized atlas segmentations\n";
    
    # Tempting to do addtozero iteratively, but this is dangerous because of header drift

    for (my $counter = 0; $counter < $numAtlases; $counter++) { 
	system("${antsPath}ThresholdImage 3 $segImagesSubjSpace[$counter] ${tmpDir}/atlasSegBinarized_${counter}.nii.gz 1 Inf");
    }

    system("${antsPath}AverageImages 3 ${tmpDir}/averageAtlasSegBinarized.nii.gz 0 ${tmpDir}/atlasSegBinarized_*.nii.gz");

    system("${antsPath}ThresholdImage 3 ${tmpDir}/averageAtlasSegBinarized.nii.gz $refMask 1E-6 Inf");
    
}

print "\n  Labeling with " . scalar(@grayImagesSubjSpace) . " atlases \n";

if ($outputMajorityVote) {
    system("${antsPath}ImageMath 3 ${tmpDir}/${outputFileRoot}MajorityLabels.nii.gz MajorityVoting " . join(" ", @segImagesSubjSpace));
    system("${antsPath}ImageMath 3 ${outputDir}/${outputFileRoot}MajorityLabels.nii.gz m $refMask ${tmpDir}/${outputFileRoot}MajorityLabels.nii.gz");
}

if ($outputJLF) {
    
    my $majorityLabels = "${tmpDir}/${outputFileRoot}MajorityLabels.nii.gz";
    my $jlfMask = "${tmpDir}/${outputFileRoot}MajorityLabels_Mask.nii.gz";

    # ImageMath call creates ${outputFileRoot}MajorityLabels.nii.gz and ${outputFileRoot}MajorityLabels_Mask.nii.gz, where 
    # the mask is voxels where we need to do JLF - but these may include voxels outside of the user supplied brain mask.
    #
    system("${antsPath}ImageMath 3 $majorityLabels MajorityVoting $jlfMajorityThresh " . join(" ", @segImagesSubjSpace));
    
    # Mask these in turn by user supplied input mask
    system("${antsPath}ImageMath 3 $majorityLabels m $refMask $majorityLabels");
    system("${antsPath}ImageMath 3 $jlfMask m $refMask $jlfMask");
    
    print "Running antsJointFusion \n";
    
    my $jlfResult = "${tmpDir}/${outputFileRoot}PGJLF.nii.gz";

    my $cmd = "${antsPath}antsJointFusion -d 3 -v 1 -t $refImage -x $jlfMask -g " . join(" -g ",  @grayImagesSubjSpace) . " -l " . join(" -l ",  @segImagesSubjSpace) . " -o $jlfResult ";
    
    print "\n$cmd\n";
    
    system($cmd);
    
    # Now integrate JLF result with majority labels
    system("${antsPath}ImageMath 3 ${outputDir}/${outputFileRoot}PGJLF.nii.gz max $jlfResult $majorityLabels");
}

# Copy input to output for easy evaluation
system("cp $refImage ${outputDir}/${outputFileRoot}Brain.nii.gz");


# Clean up

# system("rm -f ${tmpDir}/*");
# system("rmdir $tmpDir");
