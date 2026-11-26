function [ r ] = MATLABStandaloneApplication1( args )

if ~exist('args', 'var')
    args = [];
end

% Initialize the OpticStudio connection
TheApplication = InitConnection();
if isempty(TheApplication)
    % failed to initialize a connection
    r = [];
else
    try
        r = BeginApplication(TheApplication, args);
        CleanupConnection(TheApplication);
    catch err
        CleanupConnection(TheApplication);
        rethrow(err);
    end
end
end


function [r] = BeginApplication(TheApplication, args)

import ZOSAPI.*;

TheSystem = TheApplication.PrimarySystem;

% Add your custom code here...

    % =========================================================
    % 1. 路径与参数初始化 (确保这些变量在函数开头定义)
    % =========================================================
    % 用户自行指定现有光学模型路径。
    % 例如：args.modelFile = 'D:\Project\Optical_Model.zmx';
    %       args.outputDir = 'D:\Project\Results';
    scriptDir = fileparts(mfilename('fullpath'));
    baseDir = fullfile(scriptDir, 'results');
    modelFile = '';
    if isstruct(args)
        if isfield(args, 'outputDir') && ~isempty(args.outputDir)
            baseDir = char(args.outputDir);
        end
        if isfield(args, 'modelFile') && ~isempty(args.modelFile)
            modelFile = char(args.modelFile);
        end
    end
    if isempty(modelFile) || ~isfile(modelFile)
        error('Please specify an existing optical model using args.modelFile (.zmx/.zos).');
    end
    if ~exist(baseDir, 'dir'), mkdir(baseDir); end
    modelDir = fullfile(baseDir, 'Saved_Models');
    if ~exist(modelDir, 'dir'), mkdir(modelDir); end
    % =========================================================
    % 2. 扫参设置：口径、F 数与探测器半宽（单位：mm）
    % =========================================================
    D_list = [6 8 10 15 20 30 40 50];
    L_sensor = 7.68;
    F_lists = cell(1, length(D_list));
    for i = 1:length(D_list)
        D = D_list(i);
        if D <= 6
            F_lists{i} = [1.0:0.2:3.0, 3.5, 4.0];
        elseif D <= 20
            F_lists{i} = [1.0:0.1:1.6, 1.8, 2.0, 2.5, 3.0, 3.5, 4.0];
        else
            F_lists{i} = [1.0:0.05:1.2, 1.3, 1.4, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0];
        end
    end
    % 预分配结果矩阵：D、F/#、全 FOV 及五个视场的 RMS 光斑半径。
    totalTasks = 0;
    for i = 1:length(F_lists)
        totalTasks = totalTasks + length(F_lists{i});
    end
    fprintf('总计算任务数: %d\n', totalTasks);
    results_data = zeros(totalTasks, 8);
    % =========================================================
    % 3. 加载用户指定的光学模型并配置系统
    % =========================================================
    taskCounter = 0;
    for i = 1:length(D_list)
        D = D_list(i);
        current_F_list = F_lists{i};
        numF_current = length(current_F_list);
        for j = 1:numF_current
            taskCounter = taskCounter + 1;
            Fnum = current_F_list(j);
            focal_length = D * Fnum;
            half_fov = atand((L_sensor/2) / focal_length);
            fprintf('\n[任务 %d/%d] 正在处理: D=%.1f, F=%.1f\n', taskCounter, totalTasks, D, Fnum);
            
            % 每个采样点从同一初始模型重新开始，避免继承前一个任务的优化状态。
            TheSystem.LoadFile(modelFile, false);
            TheMFE = TheSystem.MFE;
            if TheSystem.SystemData.Wavelengths.NumberOfWavelengths == 0
                TheSystem.SystemData.Wavelengths.AddWavelength(10.6, 1.0);
            end
            TheSystem.SystemData.Aperture.ApertureValue = D;
            desired_fields = [0, half_fov * 0.707, half_fov, 1.0, 2.0];
            num_required = length(desired_fields);
            current_num = TheSystem.SystemData.Fields.NumberOfFields;
            if current_num < num_required
                for k = (current_num + 1) : num_required
                    TheSystem.SystemData.Fields.AddField(0, 0, 1.0);
                end
            end
            for k = 1:num_required
                TheSystem.SystemData.Fields.GetField(k).Y = desired_fields(k);
                TheSystem.SystemData.Fields.GetField(k).X = 0;
            end
            quickFocus = TheSystem.Tools.OpenQuickFocus();
            if ~isempty(quickFocus)
                try
                    quickFocus.RunAndWaitForCompletion();
                    quickFocus.Close();
                catch
                    fprintf('任务 %d: QuickFocus 运行失败，跳过聚焦。\n', taskCounter);
                    quickFocus.Close();
                end
            else
                fprintf('任务 %d: 无法打开 QuickFocus 工具，可能是光线无法追迹。\n', taskCounter);
            end
            % =========================================================
            % 4. 重建评价函数及物理约束
            % =========================================================
            for k = TheMFE.NumberOfOperands : -1 : 1
                TheMFE.RemoveOperandAt(k);
            end
            % Build the merit function and physical constraints.
            Wiz = TheMFE.SEQOptimizationWizard2;
            Wiz.Type = ZOSAPI.Wizards.OptimizationTypes.RMS;
            Wiz.Criterion = ZOSAPI.Wizards.CriterionTypes.Spot;
            Wiz.Reference = ZOSAPI.Wizards.ReferenceTypes.Centroid;
            Wiz.Rings = 8;
            Wiz.Arms = ZOSAPI.Wizards.PupilArmsCount.Arms_12;
            Wiz.OK();
            opsAfterWiz = TheMFE.NumberOfOperands;
            if opsAfterWiz == 0
                fprintf('错误：向导未能生成任何操作数！请检查模板文件的视场和波长设置。\n');
            end
            numPhysConstraints = 30;
            for k = 1:numPhysConstraints
                TheMFE.InsertNewOperandAt(1);
            end
            TheMFE.GetOperandAt(2).ChangeType(Editors.MFE.MeritOperandType.EFFL);
            TheMFE.GetOperandAt(3).ChangeType(Editors.MFE.MeritOperandType.OPGT);
            TheMFE.GetOperandAt(3).GetCellAt(2).IntegerValue = 2;
            TheMFE.GetOperandAt(3).Target = focal_length * 0.99;
            TheMFE.GetOperandAt(3).Weight = 1;
            TheMFE.GetOperandAt(4).ChangeType(Editors.MFE.MeritOperandType.OPLT);
            TheMFE.GetOperandAt(4).GetCellAt(2).IntegerValue = 2;
            TheMFE.GetOperandAt(4).Target = focal_length * 1.01;
            TheMFE.GetOperandAt(4).Weight = 1;
            TheMFE.GetOperandAt(5).ChangeType(Editors.MFE.MeritOperandType.WFNO);
            TheMFE.GetOperandAt(5).Target = Fnum;
            TheMFE.GetOperandAt(5).Weight = 1;
            TheMFE.GetOperandAt(6).ChangeType(Editors.MFE.MeritOperandType.MNCG);
            TheMFE.GetOperandAt(6).GetCellAt(2).IntegerValue = 1;
            TheMFE.GetOperandAt(6).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(6).Target = 1.6;
            TheMFE.GetOperandAt(6).Weight = 1;
            TheMFE.GetOperandAt(7).ChangeType(Editors.MFE.MeritOperandType.MNEG);
            TheMFE.GetOperandAt(7).GetCellAt(2).IntegerValue = 1;
            TheMFE.GetOperandAt(7).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(7).Target = 1.0;
            TheMFE.GetOperandAt(7).Weight = 1;
            TheMFE.GetOperandAt(8).ChangeType(Editors.MFE.MeritOperandType.MXCG);
            TheMFE.GetOperandAt(8).GetCellAt(2).IntegerValue = 1;
            TheMFE.GetOperandAt(8).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(8).Target = D*0.5;
            TheMFE.GetOperandAt(8).Weight = 1;
            TheMFE.GetOperandAt(9).ChangeType(Editors.MFE.MeritOperandType.MXCA);
            TheMFE.GetOperandAt(9).GetCellAt(2).IntegerValue = 5;
            TheMFE.GetOperandAt(9).GetCellAt(3).IntegerValue = 5;
            TheMFE.GetOperandAt(9).Target = focal_length * 0.8;
            TheMFE.GetOperandAt(9).Weight = 1;
            TheMFE.GetOperandAt(10).ChangeType(Editors.MFE.MeritOperandType.MXCA);
            TheMFE.GetOperandAt(10).GetCellAt(2).IntegerValue = 2;
            TheMFE.GetOperandAt(10).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(10).Target = focal_length * 1.2;
            TheMFE.GetOperandAt(10).Weight = 1;
            TheMFE.GetOperandAt(11).ChangeType(Editors.MFE.MeritOperandType.MXCA);
            TheMFE.GetOperandAt(11).GetCellAt(2).IntegerValue = 3;
            TheMFE.GetOperandAt(11).GetCellAt(3).IntegerValue = 3;
            TheMFE.GetOperandAt(11).Target = focal_length * 1.2;
            TheMFE.GetOperandAt(11).Weight = 1;
            TheMFE.GetOperandAt(12).ChangeType(Editors.MFE.MeritOperandType.MNCA);
            TheMFE.GetOperandAt(12).GetCellAt(2).IntegerValue = 2;
            TheMFE.GetOperandAt(12).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(12).Target = D * 0.1;
            TheMFE.GetOperandAt(12).Weight = 2;
            TheMFE.GetOperandAt(13).ChangeType(Editors.MFE.MeritOperandType.MNCA);
            TheMFE.GetOperandAt(13).GetCellAt(2).IntegerValue = 3;
            TheMFE.GetOperandAt(13).GetCellAt(3).IntegerValue = 3;
            TheMFE.GetOperandAt(13).Target = D * 0.1;
            TheMFE.GetOperandAt(13).Weight = 2;
            TheMFE.GetOperandAt(14).ChangeType(Editors.MFE.MeritOperandType.MNCA);
            TheMFE.GetOperandAt(14).GetCellAt(2).IntegerValue = 5;
            TheMFE.GetOperandAt(14).GetCellAt(3).IntegerValue = 5;
            TheMFE.GetOperandAt(14).Target = D * 0.1;
            TheMFE.GetOperandAt(14).Weight = 2;
            TheMFE.GetOperandAt(15).ChangeType(Editors.MFE.MeritOperandType.CVVA);
            TheMFE.GetOperandAt(15).GetCellAt(2).IntegerValue = 1;
            TheMFE.GetOperandAt(16).ChangeType(Editors.MFE.MeritOperandType.RECI);
            TheMFE.GetOperandAt(16).GetCellAt(2).IntegerValue = 15;
            TheMFE.GetOperandAt(17).ChangeType(Editors.MFE.MeritOperandType.CVVA);
            TheMFE.GetOperandAt(17).GetCellAt(2).IntegerValue = 2;
            TheMFE.GetOperandAt(18).ChangeType(Editors.MFE.MeritOperandType.RECI);
            TheMFE.GetOperandAt(18).GetCellAt(2).IntegerValue = 17;
            TheMFE.GetOperandAt(19).ChangeType(Editors.MFE.MeritOperandType.DIVI);
            TheMFE.GetOperandAt(19).GetCellAt(2).IntegerValue = 18;
            TheMFE.GetOperandAt(19).GetCellAt(3).IntegerValue = 16;
            TheMFE.GetOperandAt(20).ChangeType(Editors.MFE.MeritOperandType.OPGT);
            TheMFE.GetOperandAt(20).GetCellAt(2).IntegerValue = 19;
            TheMFE.GetOperandAt(20).Target = 1.1;
            TheMFE.GetOperandAt(20).Weight = 1;
            TheMFE.GetOperandAt(21).ChangeType(Editors.MFE.MeritOperandType.EFLY);
            TheMFE.GetOperandAt(21).GetCellAt(2).IntegerValue = 1;
            TheMFE.GetOperandAt(21).GetCellAt(3).IntegerValue = 2;
            TheMFE.GetOperandAt(22).ChangeType(Editors.MFE.MeritOperandType.OPGT);
            TheMFE.GetOperandAt(22).GetCellAt(2).IntegerValue = 21;
            TheMFE.GetOperandAt(22).Target = focal_length;
            TheMFE.GetOperandAt(22).Weight = 1;
            TheMFE.CalculateMeritFunction();
            % =========================================================
            % 5. DLS -> Hammer -> DLS 光学优化
            % =========================================================
            LocalOpt = TheSystem.Tools.OpenLocalOptimization();
            if ~isempty(LocalOpt)
                LocalOpt.Algorithm = ZOSAPI.Tools.Optimization.OptimizationAlgorithm.DampedLeastSquares;
                LocalOpt.Cycles = ZOSAPI.Tools.Optimization.OptimizationCycles.Automatic;
                LocalOpt.RunAndWaitForCompletion();
                LocalOpt.Close();
            end
            HammerOpt = TheSystem.Tools.OpenHammerOptimization();
            if ~isempty(HammerOpt)
                fprintf('正在执行锤形优化 (60秒)... ');
                HammerOpt.Run();
                tic;
                while toc < 60
                    pause(1);
                end
                if HammerOpt.IsRunning
                    HammerOpt.Cancel();
                end
                while HammerOpt.IsRunning
                    pause(0.1);
                end
                HammerOpt.Close();
                fprintf('锤形优化完成。\n');
                fprintf('一次锤形优化后 MF: %f\n', TheMFE.CalculateMeritFunction());
            else
                fprintf('跳过锤形优化 (可能由于许可证限制)。\n');
            end
            LocalOptFinal = TheSystem.Tools.OpenLocalOptimization();
            if ~isempty(LocalOptFinal)
                LocalOptFinal.Algorithm = ZOSAPI.Tools.Optimization.OptimizationAlgorithm.DampedLeastSquares;
                LocalOptFinal.Cycles = ZOSAPI.Tools.Optimization.OptimizationCycles.Automatic;
                LocalOptFinal.RunAndWaitForCompletion();
                fprintf('优化后 MF: %f\n', TheMFE.CalculateMeritFunction());
                LocalOptFinal.Close();
            end
            TheMFE.GetOperandAt(26).ChangeType(Editors.MFE.MeritOperandType.EFLY);
            TheMFE.GetOperandAt(26).GetCellAt(2).IntegerValue = 4;
            TheMFE.GetOperandAt(26).GetCellAt(3).IntegerValue = 5;
            TheMFE.GetOperandAt(27).ChangeType(Editors.MFE.MeritOperandType.DIVI);
            TheMFE.GetOperandAt(27).GetCellAt(2).IntegerValue = 26;
            TheMFE.GetOperandAt(27).GetCellAt(3).IntegerValue = 21;
            TheMFE.GetOperandAt(28).ChangeType(Editors.MFE.MeritOperandType.OPGT);
            TheMFE.GetOperandAt(28).GetCellAt(2).IntegerValue = 27;
            TheMFE.GetOperandAt(28).Weight = 1.0;
            normalizationRadiusMm = 1; % Binary 2 phase normalization radius used in this template (mm)
            % Stepwise optical-power-ratio optimization with phase checks.
            % =========================================================
            % 6. 渐进式光焦度约束与相位分布检查
            %    只保存通过约束的模型，失败时回退至上一有效状态。
            % =========================================================
            ratio_steps = [1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.4, 2.5, 2.6, ...
                2.7, 2.8, 2.9, 3.0, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, ...
                3.9, 4.0, 4.1, 4.2, 4.3, 4.4, 4.5, 4.8, 5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5, 9.0];
            threshold_K_edge = -0.1 * pi;
            threshold_ratio = 0.2;
            metaSurf = 5;
            lastSafeFile = fullfile(baseDir, sprintf('Task_%d_MaxValidRatio.zmx', taskCounter));
            hasValidState = false;
            for s = 1:length(ratio_steps)
                target_ratio = ratio_steps(s);
                fprintf('\n[步进优化] 尝试比例目标 -> %.2f\n', target_ratio);
                TheMFE.GetOperandAt(28).Target = target_ratio;
                LocalOpt = TheSystem.Tools.OpenLocalOptimization();
                if ~isempty(LocalOpt)
                    LocalOpt.Algorithm = ZOSAPI.Tools.Optimization.OptimizationAlgorithm.DampedLeastSquares;
                    LocalOpt.Cycles = ZOSAPI.Tools.Optimization.OptimizationCycles.Automatic;
                    LocalOpt.RunAndWaitForCompletion();
                    LocalOpt.Close();
                end
                surface = TheSystem.LDE.GetSurfaceAt(metaSurf);
                r_max = surface.SemiDiameter;
                A_vals = zeros(1, 8);
                colEnumType = ZOSAPI.Editors.LDE.SurfaceColumn().GetType();
                for k_param = 1:8
                    pName = sprintf('Par%d', k_param + 14);
                    pEnum = System.Enum.Parse(colEnumType, pName);
                    A_vals(k_param) = surface.GetSurfaceCell(pEnum).DoubleValue;
                end
                r_samples = linspace(0.01, r_max, 100);
                phase_sum = zeros(size(r_samples));
                rho_samples = r_samples / normalizationRadiusMm;
                for k_order = 1:8
                    phase_sum = phase_sum + A_vals(k_order) * (rho_samples.^(2 * k_order));
                end
                phase_profile = -1 * phase_sum;
                [val_peak, ~] = min(phase_profile);
                val_edge = phase_profile(end);
                current_ratio = val_edge / val_peak;
                [max_abs_val, idx_peak] = max(abs(phase_profile));
                r_peak = r_samples(idx_peak);
                current_K = max_abs_val / r_peak;
                fprintf('     检查结果:\n');
                fprintf('     - 边缘相位: %.2f rad (底线 < %.2f)\n', val_edge, threshold_K_edge);
                fprintf('     - 边缘/波谷比例: %.4f (要求 > %.2f)\n', current_ratio, threshold_ratio);
                fprintf('     - 参考 K 值: %.4f\n', current_K);
                condA = (val_edge < threshold_K_edge);
                condRatio = (current_ratio > threshold_ratio);
                if condA && condRatio
                    fprintf('  [符合要求] 条件A与形态比例均达标。保存并尝试更高比例。\n');
                    TheSystem.SaveAs(lastSafeFile);
                    hasValidState = true;
                    if s == length(ratio_steps)
                        fprintf('  [封顶] 已达到序列最大比例。\n');
                    end
                else
                    if ~condA
                        fprintf('  [刹车] 边缘相位(%.2f)不满足底线(%.2f)！\n', val_edge, threshold_K_edge);
                    elseif ~condRatio
                        fprintf('  [刹车] 比例(%.4f)不满足要求(>%.2f)！边缘回升过快。\n', current_ratio, threshold_ratio);
                    end
                    if hasValidState
                        fprintf('  正在回退至上一个完全达标的状态...\n');
                        TheSystem.LoadFile(lastSafeFile, false);
                        TheMFE = TheSystem.MFE;
                    else
                        fprintf('  [警告] 初始状态即不满足条件，请手动检查系统。\n');
                    end
                    break;
                end
            end
            % Extract RMS spot radius for five configured fields.
            % =========================================================
            % 7. 提取各视场 RMS 光斑半径并保存优化结果
            % =========================================================
            spotDiag = TheSystem.Analyses.New_Analysis(ZOSAPI.Analysis.AnalysisIDM.StandardSpot);
            spotSettings = spotDiag.GetSettings();
            spotSettings.ReferTo = ZOSAPI.Analysis.Settings.Spot.Reference.Centroid;
            spotDiag.ApplyAndWaitForCompletion();
            spotResults = spotDiag.GetResults();
            axis_spot = spotResults.SpotData.GetRMSSpotSizeFor(1, 1);
            middle_spot = spotResults.SpotData.GetRMSSpotSizeFor(2, 1);
            edge_spot = spotResults.SpotData.GetRMSSpotSizeFor(3, 1);
            onedu_spot = spotResults.SpotData.GetRMSSpotSizeFor(4, 1);
            twodu_spot = spotResults.SpotData.GetRMSSpotSizeFor(5, 1);
            spotDiag.Close();
            results_data(taskCounter, 1) = D;
            results_data(taskCounter, 2) = Fnum;
            results_data(taskCounter, 3) = half_fov * 2;
            results_data(taskCounter, 4) = axis_spot;
            results_data(taskCounter, 5) = middle_spot;
            results_data(taskCounter, 6) = edge_spot;
            results_data(taskCounter, 7) = onedu_spot;
            results_data(taskCounter, 8) = twodu_spot;
            modelName = sprintf('Task_%d_D%.1f_F%.1f.zmx', taskCounter, D, Fnum);
            TheSystem.SaveAs(fullfile(modelDir, modelName));
            fprintf('任务 %d 处理完毕。', taskCounter);
        end
    end
    % =========================================================
    % 8. 保存汇总数据（保留 ZOS-API 返回的原始长度单位）
    % =========================================================
    save(fullfile(baseDir, 'Optimization_Results.mat'), 'results_data');
    fprintf('\n扫参圆满完成！最终结果保存在 Optimization_Results.mat 中。\n');
    disp(results_data);
    r = results_data;
end
% 建立 ZOS-API Standalone 连接（从 Windows 注册表查找安装目录）。
function app = InitConnection()
import System.Reflection.*;
zemaxData = winqueryreg('HKEY_CURRENT_USER', 'Software\Zemax', 'ZemaxRoot');
NetHelper = strcat(zemaxData, '\ZOS-API\Libraries\ZOSAPI_NetHelper.dll');
NET.addAssembly(NetHelper);
success = ZOSAPI_NetHelper.ZOSAPI_Initializer.Initialize();
if success == 1
    LogMessage(strcat('Found OpticStudio at: ', char(ZOSAPI_NetHelper.ZOSAPI_Initializer.GetZemaxDirectory())));
else
    app = [];
    return;
end
NET.addAssembly(AssemblyName('ZOSAPI_Interfaces'));
NET.addAssembly(AssemblyName('ZOSAPI'));
TheConnection = ZOSAPI.ZOSAPI_Connection();
app = TheConnection.CreateNewApplication();
if isempty(app)
   HandleError('An unknown connection error occurred!');
end
if ~app.IsValidLicenseForAPI
    HandleError('License check failed!');
    app = [];
end
end
function LogMessage(msg)
disp(msg);
end
function HandleError(error)
ME = MException('zosapi:HandleError', error);
throw(ME);
end
% 关闭本次独立 OpticStudio 实例。
function  CleanupConnection(TheApplication)
TheApplication.CloseApplication();
end
