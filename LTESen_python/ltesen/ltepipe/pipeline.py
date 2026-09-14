"""Generic linear module pipeline."""

from __future__ import annotations

import math
from typing import Any

from .message import Message
from .module import Module
from .result import Result, validate_result
from .runtime import Runtime


class Pipeline:
    def __init__(self, execution_config: dict[str, Any] | None = None) -> None:
        self.execution_config = execution_config or {
            "maximum_iterations": math.inf,
            "verbose": False,
        }
        self.runtime = Runtime()
        self.modules: list[Module] = []
        self.state = "created"
        self.initialized = False
        self.iterations = 0
        self.finalized = False
        self.termination_reason = ""
        self.final_artifacts: list[Any] = []
        self.last_message = Message.none()

    @property
    def module_names(self) -> list[str]:
        return [module.name for module in self.modules]

    def register(self, module: Module) -> None:
        if self.initialized:
            raise RuntimeError("Modules cannot be registered after initialization")
        if not isinstance(module, Module):
            raise TypeError("Registered objects must be Module instances")
        if module.name in self.module_names:
            raise ValueError(f'Module name "{module.name}" is already registered')
        self._validate_connection(module)
        self.modules.append(module)

    def initialize(self) -> None:
        if self.initialized:
            return
        if not self.modules:
            raise RuntimeError("At least one module must be registered")
        if self.modules[0].input_type:
            raise RuntimeError("The first registered module must be a source")
        self.state = "initializing"
        for module in self.modules:
            module.initialize(self.runtime)
        self.initialized = True
        self.state = "ready"

    def step(self) -> Result:
        if self.finalized:
            raise RuntimeError("The pipeline cannot process data after finalization")
        self.initialize()
        self.state = "running"
        self.iterations += 1
        result = self._run_modules(0, Message.none())
        self.last_message = result.message
        self.state = "stopping" if result.directive == "stop" else "ready"
        return result

    def run(self) -> dict[str, Any]:
        maximum = self._maximum_iterations()
        termination_reason = "maximum-iterations"
        try:
            while self.iterations < maximum:
                result = self.step()
                if result.directive == "stop":
                    termination_reason = result.reason
                    break
            self.finalize(termination_reason)
        except Exception:
            self.state = "failed"
            try:
                self.finalize("failed")
            except Exception:
                pass
            raise

        summary = self.get_status()
        if self._verbose():
            print(
                f"Pipeline completed after {self.iterations} iterations "
                f"({self.termination_reason})."
            )
        return summary

    def finalize(self, reason: str = "completed") -> list[Any]:
        if self.finalized:
            return self.final_artifacts
        self.initialize()
        self.state = "finalizing"
        artifacts: list[Any] = []
        for index, module in enumerate(self.modules):
            module_result = module.finalize(reason)
            validate_result(module_result)
            self._dispatch_commands(module_result.commands)
            if module_result.message.has_content:
                routed = self._run_modules(index + 1, module_result.message)
                artifacts.extend(routed.message.artifacts)
        self.final_artifacts = artifacts
        self.termination_reason = reason
        self.finalized = True
        self.state = "failed" if reason == "failed" else "finalized"
        return artifacts

    def get_module(self, name: str) -> Module:
        for module in self.modules:
            if module.name == name:
                return module
        raise KeyError(f'Module "{name}" is not registered')

    def get_status(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "iterations": self.iterations,
            "initialized": self.initialized,
            "finalized": self.finalized,
            "termination_reason": self.termination_reason,
            "modules": [
                {
                    "name": module.name,
                    "class": type(module).__name__,
                    "status": module.get_status(),
                }
                for module in self.modules
            ],
            "runtime": self.runtime.get_status(),
            "final_artifacts": self.final_artifacts,
        }

    def _run_modules(self, first_index: int, message: Message) -> Result:
        result = Result.forward(message)
        for index in range(first_index, len(self.modules)):
            result = self.modules[index].process(result.message)
            validate_result(result)
            self._dispatch_commands(result.commands)
            if result.directive == "continue":
                continue
            if result.directive == "reset-downstream":
                event = {
                    "epoch": result.epoch,
                    "reason": result.reason,
                    "source": self.modules[index].name,
                }
                for module in self.modules[index + 1 :]:
                    module.reset(event)
            return result
        return result

    def _dispatch_commands(self, commands: tuple[Any, ...]) -> None:
        for command in commands:
            if not isinstance(command, dict) or not all(
                key in command for key in ("target", "type")
            ):
                if isinstance(command, dict) and all(
                    key in command for key in ("Target", "Type")
                ):
                    command = {
                        "target": command["Target"],
                        "type": command["Type"],
                        **command,
                    }
                else:
                    raise ValueError("Commands require target and type fields")
            self.get_module(command["target"]).handle_command(command)

    def _validate_connection(self, module: Module) -> None:
        if not self.modules:
            return
        previous = self.modules[-1]
        if previous.output_type and module.input_type and previous.output_type != module.input_type:
            raise ValueError(
                f'Module "{previous.name}" outputs "{previous.output_type}", '
                f'but module "{module.name}" expects "{module.input_type}"'
            )

    def _maximum_iterations(self) -> float:
        value = self.execution_config.get(
            "maximum_iterations", self.execution_config.get("maximum_subframes", math.inf)
        )
        if value is None:
            return math.inf
        if not isinstance(value, (int, float)) or value <= 0:
            raise ValueError("maximum_iterations must be a positive number or null")
        return float(value)

    def _verbose(self) -> bool:
        return bool(self.execution_config.get("verbose", False))


__all__ = ["Pipeline"]
