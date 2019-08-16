function results = WrapperAnalyzePRF(workbench_path,stimFileName,dataFileName,dataFileType,tr,outpath,varargin)
% Wrapper to manage inputs to Kendrick Kay's analyze pRF code
%
% Syntax:
%  WrapperAnalyzePRF(stimFileName,dataFileName,tr,outpath)
%
% Description:
%   Details on the pRF model:
%   - Before analysis, we zero out any voxel that has a non-finite value or
%   has all zeros in at least one of the runs.  This prevents weird issues 
%   due to missing or bad data. 
%   - The pRF model that is fit is similar to that described in Dumoulin 
%   and Wandell (2008), except that a static power-law nonlinearity is 
%   added to the model.  This new model, called the Compressive Spatial 
%   Summation (CSS) model, is described in Kay, Winawer, Mezer, & Wandell 
%   (2013).
%   - The model involves computing the dot-product between the stimulus and
%   a 2D isotropic Gaussian, raising the result to an exponent, scaling the
%   result by a gain factor, and then convolving the result with a 
%   hemodynamic response function (HRF).  Polynomial terms are included 
%   (on a run-by-run basis) to model the baseline signal level.
% - The 2D isotropic Gaussian is scaled such that the summation of the 
%   values in the Gaussian is equal to one. This eases the interpretation 
%   of the gain of the model.
% - The exponent parameter in the model is constrained to be non-negative.
% - The gain factor in the model is constrained to be non-negative; this 
%   aids the interpretation of the model (e.g. helps avoid voxels with 
%   negative BOLD responses to the stimuli).
% - The workhorse of the analysis is fitnonlinearmodel.m, which is 
%   essentially a wrapper around routines in the MATLAB Optimization 
%   Toolbox. We use the Levenberg-Marquardt algorithm for optimization, 
%   minimizing squared error between the model and the data.
% - A two-stage optimization strategy is used whereby all parameters 
%   excluding the exponent parameter are first optimized (holding the 
%   exponent parameter fixed) and then all parameters are optimized 
%   (including the exponent parameter).This strategy helps avoid local 
%   minima.
%
%
%   Note: All variable inputs are in the form of strings. This is to
%   support compilation.
%
%
% Inputs:
%   workbench_path        - String. path to workbench_command
%   stimFileName          - String. .mat file. Provides the apertures as a  
%                           cell vector of R x C x time. Values should be 
%                           in [0,1].The number of time points can differ 
%                           across runs. The variable needs be named
%                           stimulus.
%   dataFileName          - String. Provides the data as a cell vector of 
%                           voxels x time.the number of time points should 
%                           match the number of time points in <stimulus>.
%   dataFileType          - String. Select whether the data is volumetric
%                           surface(CIFTI).
%   tr                    - String. The TR in seconds (e.g. 1.5)                          
%   outpath               - String. Output path without the save file name.
%                           needs to end with a /
% Optional key/value pairs:
%  
%  'wantglmdenoise'         - String. (optional) is whether to use GLMdenoise
%                           to determine nuisance regressors to add into 
%                           the PRF model.  note that in order to use this 
%                           feature, there must be at least two runs (and 
%                           conditions must repeat across runs). 
%                           We automatically determine the GLM design 
%                           matrix based on the contents of <stimulus>.  
%                           Special case is to pass in the noise regressors 
%                           directly (e.g. from a previous call).default: 0
%  'hrf'                    - String. (optional) is a column vector with the
%                           hemodynamic response function (HRF) to use in 
%                           the model. The first value of <hrf> should be
%                           coincident with the onset of the stimulus, and 
%                           the HRF should indicate the timecourse of the 
%                           response to a stimulus that lasts for one TR.  
%                           Default is to use a canonical HRF (calculated 
%                           using getcanonicalhrf(tr,tr)').
%  'maxpolydeg'             - String. Is a non-negative integer indicating 
%                           the maximum polynomial degree to use for drift 
%                           terms. Can be a vector whose length matches the
%                           number of runs in <data>.  default is to use 
%                           round(L/2) where L is the number of minutes
%                           in the duration of a given run.
%  'seedmode'               - String. Is a vector consisting of one or 
%                           more of the following values (we automatically 
%                           sort and ensure uniqueness):
%                           0 means use generic large PRF seed
%                           1 means use generic small PRF seed
%                           2 means use best seed based on super-grid
%                           default: [0 1 2].
%  'xvalmode'              - String.
%                           0 means just fit all the data
%                           1 means two-fold cross-validation (first half 
%                           of runs; second half of runs)
%                           2 means two-fold cross-validation (first half               
%                           of each run; second half of each run)
%                           default: 0.  (note that we round when halving.)
%  'numperjob'             - String.[] means to run locally (not on the cluster)
%                           N where N is a positive integer indicating the 
%                           number of voxels to analyze in each cluster job
%                           this option requires a customized computational 
%                           setup! default: Na.
%  'maxiter'               - String. Is the maximum number of iterations.  
%                           default: 500.
%  'display'               - String.is 'iter' | 'final' | 'off'.  
%                           default: 'iter'.
%  'typicalgain'           - String. Is a typical value for the gain in 
%                           each time-series. Default: 10.
%  'maskFileName'          - String. Path to the mask. If not used, all
%                           voxels in the data file are analyzed.
%  'prependDummyTRs'       - String. Used when the stimulus and data
%                           lengths are not equal and the inequality is 
%                           caused due to the removal of dummy TRs from
%                           the sample. Calculates the mean along the time
%                           dimension for each voxel and adds that mean at
%                           the beginning of the data (multiple times if
%                           required until data and stimulus sample lengths
%                           are exactly the same. Don't use this option if
%                           the difference is due to sampling. 1 for true 
%                           and 0 for false. Default = 0 (false)
%   'thresholdData'        - String. Threshold with this percent. Default:10
%   'pixelToDegree'        - String. If a pixel to degree number is
%                           specified, eccentricity values are represented 
%                           on this scale.
%
% Outputs:
%   none
%
% Examples:
%{
    % Run the wrapper using Kendrick's example data. The path to Kendrick's
    % data is currently hard-coded
    examplePath='~/Documents/MATLAB/toolboxes/analyzePRF/exampledataset.mat';
    load(examplePath,'stimulus','data')

    % Kendrick's example fMRI data must be resampled to match the time
    % domain of the stimulus
    data = tseriesinterp(data,2,1,2);

    % We reshape the data to be a 2x2x2 volume and save as a nifti file
    tempData=reshape(data{1}(1:8,:),[2 2 2 300]);
    tempNiftiPath='~/Desktop/tempNifti.nii';
    niftiwrite(tempData, tempNiftiPath)

    % Save the stimulus file
    tempStimFilePath='~/Desktop/tempStim.mat';
    stimulus=stimulus{1};
    save(tempStimFilePath,'stimulus');

    % Run the wrapper function
    tr='1';
    outpath='~/Desktop/tempResults.mat';
    WrapperAnalyzePRF(tempStimFilePath,tempNiftiPath,tr,outpath);
%}




%% Parse vargin for options passed here

p = inputParser; p.KeepUnmatched = true;

% Required  
p.addRequired('workbench_path',@isstr);
p.addRequired('stimFileName',@isstr);
p.addRequired('dataFileName',@isstr);
p.addRequired('dataFileType',@isstr);
p.addRequired('tr', @isstr);
p.addRequired('outpath', @isstr);

% Optional parameters
p.addParameter('wantglmdenoise',"0",@isstr);
p.addParameter('hrf',"Na",@isstr);   %MAT FILE, COLUMN VECTOR
p.addParameter('maxpolydeg',"Na",@isstr);
p.addParameter('seedmode',"[0 1 2]",@isstr);
p.addParameter('xvalmode',"0",@isstr);
p.addParameter('numperjob',"Na",@isstr);
p.addParameter('maxiter',"500",@isstr);
p.addParameter('display',"iter",@isstr);
p.addParameter('typicalgain',"10",@isstr);
p.addParameter('maskFileName',"Na", @isstr);
p.addParameter('prependDummyTRs',"0", @isstr)
p.addParameter('thresholdData',"10", @isstr)
p.addParameter('pixelToDegree',"Na", @isstr)

% parse
p.parse(workbench_path, stimFileName, dataFileName, dataFileType, tr, outpath, varargin{:})

%% Load Data

% If the input does not end with gz then gear will extract the zip into a
% folder and this part of the script will go to that folder, find all the
% hp2000_clean volumes, and exclude the folder containing the avarage of 
% all runs which is usually the first folder in the ica results.
if dataFileName(end-1:end) ~= "gz" & dataFileName(end-2:end) ~= "nii"
    
    %d = dir('/flywheel/v0/input/DataFile/*/*/MNINonLinear/Results'); % Find the acquisitions
    d = dir('/*/*/*/*/*/*/*/MNINonLinear/Results'); % Find the acquisitions                             % DELET THIS
    d = d(~ismember({d.name},{'.','..'})); % get rid of "." and ".." items in the cell containing path names
    d(1) = []; % Get rid of the first folder which is that first large folder we don't want
    runNumber = length(d); % Get the number of runs
    
    if dataFileType == "volumetric"
        for ii = 1:runNumber % This creates a data cell 1xrunNumber and populates the cells with the data
            rawName{ii} = strcat(d(ii).folder,'/', d(ii).name, '/', d(ii).name, '_', 'hp2000_clean.nii.gz');
            data{ii} = MRIread(rawName{ii});
            data{ii} = data{ii}.vol;  %only get the volume
            data{ii} = single(data{ii}); %convert to single
            data{ii} = reshape(data{ii}, [size(data{ii},1)*size(data{ii},2)*size(data{ii},3), size(data{ii},4)]);
            data{ii}(isnan(data{ii})) = 0; %NaN to 0
        end
    elseif dataFileType == "cifti"
        for ii = 1:runNumber % This creates a data cell 1xrunNumber and populates the cells with the data
            fprintf(strcat("Reading cifti number", ' ', num2str(ii), '\n'))
            rawName{ii} = strcat(d(ii).folder,'/', d(ii).name, '/', d(ii).name, '_', 'Atlas_hp2000_clean.dtseries.nii');
            temporary = ciftiopen(rawName{ii}, workbench_path);
            data{ii} = temporary.cdata; 
            %data{ii} = data.cdata;
            %data{ii} = ft_read_cifti(rawName{ii});
            %datafnames = fieldnames(data{ii});
            %data{ii} = data{ii}.(datafnames{end});  %only get the last element which is the volume
            %data{ii} = single(data{ii}); %convert to single    
            %data{ii}(isnan(data{ii})) = 0; %NaN to 0
        end 
    else
        fprintf("Scan type is not valid")
    end
    
else   % This is used when a single acquisition is analyzed
    runNumber = 1;
    if dataFileType == "volumetric"
        rawData = MRIread(p.Results.dataFileName);
        data = rawData.vol;
        data = single(data);
        data = reshape(data, [size(data,1)*size(data,2)*size(data,3), size(data,4)]); % Convert 4D to 2D
    elseif dataFileType == "cifti"
        rawData = ciftiopen(p.Results.dataFileName, workbench_path);
        data = rawData.cdata;
        %data = single(data);
    else
        fprintf("Scan type is not valid")
    end
end

%% Load the stimulus, convert to single, and copy it to the other cells
%  so that the cell size of the stimulus matches the cell size of the data

load(stimFileName,'stimulus');
stimulus = single(stimulus); 
dataLength = length(data);
stimLength = length(stimulus);
if dataLength ~= stimLength
    temporarystim = stimulus;
    stimulus = {};
    for celvar = 1:dataLength
        stimulus{celvar} = temporarystim;
    end
end

% massage cell inputs
if ~iscell(stimulus)
  stimulus = {stimulus};
end
if ~iscell(data)
  data = {data};
end

% determine how many voxels to analyze 

if p.Results.maskFileName ~= "Na"    % Get the indices from mask if specified
    if dataFileType == "volumetric"
        rawMask = MRIread(p.Results.maskFileName); % Load mask
        mask = rawMask.vol;  % Get only the volume
        mask = single(mask); % Convert mask volume to single
        mask = reshape(mask, [size(mask,1)*size(mask,2)*size(mask,3),1]); % Reshape
        vxs = find(mask)';
        vxs = single(vxs);
    elseif dataFileType == "cifti"
        rawMask = ciftiopen(p.Results.maskFileName, workbenc_path); % Load mask
        mask = rawMask.cdata;
        %mask = rmfield(rawMask, {'dimord','hdr', 'unit','brainstructure','brainstructurelabel','dim','pos','transform'}); %remove this and isolate the mask (needed because mask subfield changes names with different masks)
        %maskfnames = fieldnames(mask);
        %if numel(maskfnames) == 1
        %    mask = mask.(maskfnames{1,1});  % Get only the volume
        %    mask = single(mask); % Convert mask volume to single
        %end
        %mask(isnan(mask)) = 0; % Get rid of NaNs or find function will get their indices too
        vxs = find(mask)';
        vxs = single(vxs);    
    end
    
else                                   % Analyze all voxels if no mask is specified 
    is3d = size(data{1},4) > 1;
    if is3d
      dimdata = 3;
      dimtime = 4;
      xyzsize = sizefull(data{1},3);
    else
      dimdata = 1;
      dimtime = 2;
      xyzsize = size(data{1},1);
    end
    numvxs = prod(xyzsize);
    vxs = 1:numvxs;
end

% MCR only accepts strings. This part converts variables which are passed
% as strings to vectors and numericals.

tr = str2double(tr);
listofnums = ['0','1','2','3','4','5','6','7','8','9'];
new_seedmode = [];
if p.Results.maxpolydeg ~= "Na"
    new_maxpolydeg = str2double(p.Results.maxpolyreg);
else 
    new_maxpolydeg = [];
end

if p.Results.numperjob ~= "Na"
    new_numperjob = str2double(p.Results.numperjob);
else
    new_numperjob = [];
end

if p.Results.hrf ~= "Na"
    new_hrf = load(p.Results.hrf,'hrf');
    new_hrf = new_hrf.hrf;
else
    new_hrf = [];
end 

for ii = p.Results.seedmode
    if ismember(ii, listofnums)
        new_seedmode = [new_seedmode,str2double(ii)];
    end
end

% Check that the stimulus and data are of the same temporal length. If they
% are not same, but prependDummyTR command is issued, add the mean of the 
% time series for each voxel at the beginning of the matrix until the data 
% and stimulus matrix lengths become equal.

if dataFileName(end-1:end) ~= "gz" % This part does it for multiple runs
     for ii = 1:runNumber
         datasizes = size(data{ii});
         data_temporal_size = datasizes(2);
         stimsizes = size(stimulus{ii});
         stim_temporal_size = stimsizes(3);
         if data_temporal_size < stim_temporal_size
             if str2double(p.Results.prependDummyTRs) == 1
                 warning("prependDummyTR function is enabled")
                 difference = stim_temporal_size - data_temporal_size;
                 means_of_rows = mean(data, 2);
                 for change = 1:difference
                     data = horzcat(means_of_rows, data);
                 end
             else
                 errorMessage = "Sample lengths of the stimulus and data are not equal for the run number. Either resample your data or consider prependDummyTR option";
                 errorMessage = insertAfter(errorMessage, 'number', num2str(ii)); 
                 error(errorMessage)
             end
         end
     end
     
else                                %This one does it for single run
    datasizes = size(data{1});
    data_temporal_size = datasizes(2);
    stimsizes = size(stimulus{1});
    stim_temporal_size = stimsizes(3);

    if data_temporal_size < stim_temporal_size
        if str2double(p.Results.prependDummyTRs) == 1
            warning("prependDummyTR function is enabled")
            difference = stim_temporal_size - data_temporal_size;
            means_of_rows = mean(data, 2);
            for i = 1:difference
                data = horzcat(means_of_rows, data);
            end 
        else
            error("Sample lengths of the stimulus and data are not equal. Either resample your data or consider prependDummyTR option")
        end
    end
end
    
    

% Prepare the final structure and convert the remaining variables to
% numerical
analysisStructure = struct('vxs',vxs,'wantglmdenoise',str2double(p.Results.wantglmdenoise),'hrf',new_hrf, ...
    'maxpolydeg',new_maxpolydeg,'seedmode',new_seedmode,'xvalmode',str2double(p.Results.xvalmode), ...
    'numperjob',new_numperjob,'maxiter',str2double(p.Results.maxiter),'display',p.Results.display, ...
    'typicalgain',str2double(p.Results.typicalgain));

% Get rid of the unwanted variables to save memory

clear d 
clear rawData
clear temporarystim
clear rawMask
clear listofnums
clear celvar
clear datasizes 
clear data_temporal_size
clear stim_temporal_size
clear mask

% Run the function and save the results
results = analyzePRF(stimulus,data,tr,analysisStructure);
save(strcat(outpath,"retinotopy_results.mat"),'results')

% Code here to reformat the results into brain maps, respecting the mask
% that was defined above, and then save the image maps someplace. Also, we
% will want to save some pictures that illustrate what the image map
% outputs look like.


%% Load the raw image again to modify and make maps

if dataFileType == "volumetric"
    rawData = MRIread(p.Results.dataFileName);
    %MAKE 3D
    getsize = size(rawData.vol); %Get the size of the original scan 
    % Results converted 2D -> 3D
    results.ecc = reshape(results.ecc,[getsize(1) getsize(2) getsize(3) 1]);
    results.ang = reshape(results.ang,[getsize(1) getsize(2) getsize(3) 1]);
    results.expt = reshape(results.expt,[getsize(1) getsize(2) getsize(3) 1]);
    results.rfsize = reshape(results.rfsize,[getsize(1) getsize(2) getsize(3) 1]);
    results.R2 = reshape(results.R2,[getsize(1) getsize(2) getsize(3) 1]);
    results.gain = reshape(results.gain,[getsize(1) getsize(2) getsize(3) 1]);
else 
    rawData = ciftiopen(rawName{1,1}, workbench_path);
end

% REPLACE NANs WITH 0 - This is not needed but some softwares (eg. freeview) 
% throws warnings when there are NaNs in the data. This stops it.
% results.ecc(isnan(results.ecc)) = 0;
% results.ang(isnan(results.ang)) = 0;
% results.expt(isnan(results.expt)) = 0; 
% results.rfsize(isnan(results.rfsize)) = 0; 
% results.R2(isnan(results.R2)) = 0; 
% results.gain(isnan(results.gain)) = 0; 

% Whenever there is a zero value in ecccentricity map set angle to NaN
zero_indices_ecc = find(results.ecc == 0);
for zero_vals = zero_indices_ecc'
    results.ang(zero_vals) = NaN;
end

%%%Pixel to Degrees conversion  
if p.Results.pixelToDegree ~= "Na"
    results.ecc = results.ecc ./ str2double(p.Results.pixelToDegree);
    results.rfsize = results.rfsize ./ str2double(p.Results.pixelToDegree);
end

%%%THRESHOLDING
if p.Results.thresholdData ~= "Na"
    threshold = str2double(p.Results.thresholdData); % Convert string to num
    ins = find(results.R2 < threshold); % Find the indices under threshold
    results_thresh = results; 
    for ii = ins'  % Remove the values under threshold from all maps
        results_thresh.ang(ii) = 0;
        results_thresh.ecc(ii) = 0;
        results_thresh.expt(ii) = 0;
        results_thresh.rfsize(ii) = 0;
        results_thresh.R2(ii) = 0;
        results_thresh.gain(ii) = 0;        
    end
end

%SAVE NIFTI or CIFTI results
if dataFileType == "volumetric"
    rawData.nframes = 1; %Set the 4th dimension 1
    rawData.vol = results.ecc;
    MRIwrite(rawData, strcat(outpath,'eccentricity_map.nii.gz'))
    rawData.vol = results.ang;
    MRIwrite(rawData, strcat(outpath,'angular_map.nii.gz'))
    rawData.vol = results.expt;
    MRIwrite(rawData, strcat(outpath,'exponent_map.nii.gz'))
    rawData.vol = results.rfsize;
    MRIwrite(rawData, strcat(outpath,'rfsize_map.nii.gz'))
    rawData.vol = results.R2;
    MRIwrite(rawData, strcat(outpath,'R2_map.nii.gz'))
    rawData.vol = results.gain;
    MRIwrite(rawData, strcat(outpath,'gain_map.nii.gz'))
    if p.Results.thresholdData ~= "Na"
        rawData.nframes = 1; %Set the 4th dimension 1
        rawData.vol = results_thresh.ecc;
        MRIwrite(rawData, strcat(outpath,'thresh_eccentricity_map.nii.gz'))
        rawData.vol = results_thresh.ang;
        MRIwrite(rawData, strcat(outpath,'thresh_angular_map.nii.gz'))
        rawData.vol = results_thresh.expt;
        MRIwrite(rawData, strcat(outpath,'thresh_exponent_map.nii.gz'))
        rawData.vol = results_thresh.rfsize;
        MRIwrite(rawData, strcat(outpath,'thresh_rfsize_map.nii.gz'))
        rawData.vol = results_thresh.R2;
        MRIwrite(rawData, strcat(outpath,'thresh_R2_map.nii.gz'))
        rawData.vol = results_thresh.gain;
        MRIwrite(rawData, strcat(outpath,'thresh_gain_map.nii.gz'))
    end
elseif dataFileType == "cifti"   % This might neet to change a little bit (not tested)
    rawData.cdata = results.ecc;
    ciftisave(rawData, strcat(outpath,'eccentricity_map.dtseries.nii'), workbench_path)
    rawData.cdata = results.ang;
    ciftisave(rawData, strcat(outpath,'angular_map.dtseries.nii'), workbench_path)
    rawData.cdata = results.expt;
    ciftisave(rawData, strcat(outpath,'exponent_map.dtseries.nii'), workbench_path)
    rawData.cdata = results.rfsize;
    ciftisave(rawData, strcat(outpath,'rfsize_map.dtseries.nii'), workbench_path)
    rawData.cdata = results.R2;
    ciftisave(rawData, strcat(outpath,'R2_map.dtseries.nii'), workbench_path)
    rawData.cdata = results.gain;
    ciftisave(rawData, strcat(outpath,'gain_map.dtseries.nii'), workbench_path)
%     rawData.time = 0;
%     finaldatafnames = fieldnames(rawData);
%     rawData.(finaldatafnames{end}) = results.ecc;
%     ft_write_cifti(strcat(outpath,'eccentricity_map'), rawData, 'parameter', finaldatafnames{end})
%     rawData.(finaldatafnames{end}) = results.ang;
%     ft_write_cifti(strcat(outpath, 'angular_map'), rawData, 'parameter', finaldatafnames{end})
%     rawData.(finaldatafnames{end}) = results.expt;
%     ft_write_cifti(strcat(outpath,'exponent_map'), rawData, 'parameter', finaldatafnames{end})
%     rawData.(finaldatafnames{end}) = results.rfsize;
%     ft_write_cifti(strcat(outpath,'rfsize_map'), rawData, 'parameter', finaldatafnames{end})
%     rawData.(finaldatafnames{end}) = results.R2;
%     ft_write_cifti(strcat(outpath, 'R2_map'), rawData, 'parameter', finaldatafnames{end})
%     rawData.(finaldatafnames{end}) = results.gain;
%     ft_write_cifti(strcat(outpath,'gain_map'), rawData, 'parameter', finaldatafnames{end})  
    if p.Results.thresholdData ~= "Na"
        rawData.cdata = results_thresh.ecc;
        ciftisave(rawData, strcat(outpath,'thresh_eccentricity_map.dtseries.nii'), workbench_path)
        rawData.cdata = results_thresh.ang;
        ciftisave(rawData, strcat(outpath,'thresh_angular_map.dtseries.nii'), workbench_path)
        rawData.cdata = results_thresh.expt;
        ciftisave(rawData, strcat(outpath,'thresh_exponent_map.dtseries.nii'), workbench_path)
        rawData.cdata = results_thresh.rfsize;
        ciftisave(rawData, strcat(outpath,'thresh_rfsize_map.dtseries.nii'), workbench_path)
        rawData.cdata = results_thresh.R2;
        ciftisave(rawData, strcat(outpath,'thresh_R2_map.dtseries.nii'), workbench_path)
        rawData.cdata = results_thresh.gain;
        ciftisave(rawData, strcat(outpath,'thresh_gain_map.dtseries.nii'), workbench_path)
%         rawData.time = 0;
%         rawData.(finaldatafnames{end}) = results_thresh.ecc;
%         ft_write_cifti(strcat(outpath,'thresh_eccentricity_map'), rawData, 'parameter', finaldatafnames{end})
%         rawData.(finaldatafnames{end}) = results_thresh.ang;
%         ft_write_cifti(strcat(outpath,'thresh_angular_map'), rawData, 'parameter', finaldatafnames{end})
%         rawData.(finaldatafnames{end}) = results_thresh.expt;
%         ft_write_cifti(strcat(outpath,'thresh_exponent_map'), rawData, 'parameter', finaldatafnames{end})
%         rawData.(finaldatafnames{end}) = results_thresh.rfsize;
%         ft_write_cifti(strcat(outpath,'thresh_rfsize_map'), rawData, 'parameter', finaldatafnames{end})
%         rawData.(finaldatafnames{end}) = results_thresh.R2;
%         ft_write_cifti(strcat(outpath,'thresh_R2_map'), rawData, 'parameter', finaldatafnames{end})
%         rawData.(finaldatafnames{end}) = results_thresh.gain;
%         ft_write_cifti(strcat(outpath,'thresh_gain_map'), rawData, 'parameter', finaldatafnames{end})
    end
end
end
