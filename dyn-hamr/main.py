
import os
import hydra

from omegaconf import DictConfig, OmegaConf
from pathlib import Path

from vipe import get_config_path, make_pipeline
from vipe.streams.base import ProcessedVideoStream
from vipe.streams.raw_mp4_stream import RawMp4Stream
from vipe.utils.logging import configure_logging
from util.logger import Logger
from data import get_dataset_from_cfg, expand_source_paths
from optim.output import save_track_info
from util.tensor import get_device
from run_opt import run_opt, set_seed
from run_vis import run_vis


def infer_vipe(video: Path, output: Path, pipeline: str, visualize: bool):
    """Run inference on a video file."""

    logger = configure_logging()

    overrides = [f"pipeline={pipeline}", f"pipeline.output.path={output}", "pipeline.output.save_artifacts=true"]
    if visualize:
        overrides.append("pipeline.output.save_viz=true")
        overrides.append("pipeline.slam.visualize=true")
    else:
        overrides.append("pipeline.output.save_viz=false")

    with hydra.initialize_config_dir(config_dir=str(get_config_path()), version_base=None):
        args = hydra.compose("default", overrides=overrides)

    logger.info(f"Processing {video}...")
    vipe_pipeline = make_pipeline(args.pipeline)

    # Some input videos can be malformed, so we need to cache the videos to obtain correct number of frames.
    video_stream = ProcessedVideoStream(RawMp4Stream(video), []).cache(desc="Reading video stream")

    vipe_pipeline.run(video_stream) 
    logger.info("Finished")


def infer_dynhamr(cfg: DictConfig):
    OmegaConf.register_new_resolver("eval", eval)
    print('run_opt.py: ', cfg)

    # Set random seed
    set_seed(cfg.get('seed', 42))

    out_dir = os.getcwd()
    print("out_dir", out_dir)
    Logger.init(f"{out_dir}/opt_log.txt")

    # make sure we get all necessary inputs
    print("init SOURCES", cfg.data.sources)
    cfg.data.sources = expand_source_paths(cfg.data.sources)
    print("SOURCES", cfg.data.sources)

    dataset = get_dataset_from_cfg(cfg)
    save_track_info(dataset, out_dir)
    os.environ["CUDA_VISIBLE_DEVICES"] = str(cfg.get("gpu"))
    print("CUDA_VISIBLE_DEVICES", os.environ["CUDA_VISIBLE_DEVICES"])
    device_id = cfg.get("gpu")

    if cfg.run_opt:
        device = get_device(device_id)
        run_opt(cfg, dataset, out_dir, device)

    if cfg.run_vis:
        run_vis(
            cfg, dataset, out_dir, device_id, **cfg.get("vis", dict())
        )


@hydra.main(version_base=None, config_path="confs", config_name="config.yaml")
def main(cfg: DictConfig):
    if cfg.get("use_vipe", False):
        infer_vipe(cfg.data.video, Path(cfg.out_path), cfg.pipeline, cfg.visualize)
    
    infer_dynhamr(cfg)