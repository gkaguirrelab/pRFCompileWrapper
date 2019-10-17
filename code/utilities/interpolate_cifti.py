import neuropythy as ny
import os 

def interpolate_cifti(path_to_inferred_maps, path_to_hcp, output):

    sub = ny.hcp_subject(path_to_hcp, default_alignment='FS')
    angle_ecc_maps = {}
    angle_ecc_maps['lh_angle'] = ny.load(os.path.join(path_to_inferred_maps, 'lh.inferred_angle.mgz'))
    angle_ecc_maps['rh_angle'] = ny.load(os.path.join(path_to_inferred_maps, 'rh.inferred_angle.mgz'))
    angle_ecc_maps['lh_eccen'] = ny.load(os.path.join(path_to_inferred_maps, 'lh.inferred_eccen.mgz'))
    angle_ecc_maps['rh_eccen'] = ny.load(os.path.join(path_to_inferred_maps, 'rh.inferred_eccen.mgz'))
 
    other_maps_left = {}
    other_maps_left['lh_sigma'] = ny.load(os.path.join(path_to_inferred_maps, 'lh.inferred_sigma.mgz'))
    other_maps_left['lh_varea'] = ny.load(os.path.join(path_to_inferred_maps, 'lh.inferred_varea.mgz'))
    
    other_maps_right = {}
    other_maps_right['rh_sigma'] = ny.load(os.path.join(path_to_inferred_maps, 'rh.inferred_sigma.mgz'))
    other_maps_right['rh_varea'] = ny.load(os.path.join(path_to_inferred_maps, 'rh.inferred_varea.mgz'))    
    
    # convert from angle/eccen to x/y (to avoid circular interpolation errors);
    # also, this function expects that 'polar_angle' means clockwise degrees from
    # vertical
    (x,y) = ny.as_retinotopy({'polar_angle':angle_ecc_maps['lh_angle'], 'eccentricity':angle_ecc_maps['lh_eccen']}, 'geographical')
    # interpolate over to fs_LR 164k mesh
    (xLR, yLR) = sub.lh.interpolate(sub.hemis['lh_LR32k'], [x, y])
    # convert back to angle and eccen
    (angLR, eccLR) = ny.as_retinotopy({'x':xLR, 'y':yLR}, 'visual')
    
    ny.save('/home/ozenc/Desktop/volumed/lh.inferred_angle.nii', angLR)
    ny.save('/home/ozenc/Desktop/volumed/lh.inferred_eccen,nii', eccLR)
    
    # Convert right
    (x,y) = ny.as_retinotopy({'polar_angle':angle_ecc_maps['rh_angle'], 'eccentricity':angle_ecc_maps['rh_eccen']}, 'geographical')
    # interpolate over to fs_LR 164k mesh
    (xLR, yLR) = sub.rh.interpolate(sub.hemis['rh_LR32k'], [x, y])
    # convert back to angle and eccen
    (angRR, eccRR) = ny.as_retinotopy({'x':xLR, 'y':yLR}, 'visual')
    
    ny.save('/home/ozenc/Desktop/volumed/rh.inferred_angle.nii', angRR)
    ny.save('/home/ozenc/Desktop/volumed/rh.inferred_eccen,nii', eccRR)
    
    for i in other_maps_left.keys():
        interpolated = sub.lh.interpolate(sub.hemis['lh_LR32k'], other_maps_left[i])
        name = str(i) + '.nii'
        ny.save(os.path.join(output, name), interpolated)
    for i in other_maps_right.keys():
        interpolated = sub.rh.interpolate(sub.hemis['rh_LR32k'], other_maps_right[i])
        name =  str(i) + '.nii'
        ny.save(os.path.join(output, name), interpolated)        

interpolate_cifti('/home/ozenc/Desktop/inferred_surface/opt/firstOutput/', '/home/ozenc/Desktop/TOME_3045_hcpstruct/TOME_3045', '/home/ozzy/Desktop/area_experimentalis/')