////////////////////////////////////////////////////////////////////////////////////////////////////
// project:   CluTec.Cuda.MultiView
// file:      Statistics.DispDenoise.cu
//
// summary:   statistics. disp denoise class
//
//            Copyright (c) 2019 by Christian Perwass.
//
//            This file is part of the CluTecLib library.
//
//            The CluTecLib library is free software: you can redistribute it and / or modify
//            it under the terms of the GNU Lesser General Public License as published by
//            the Free Software Foundation, either version 3 of the License, or
//            (at your option) any later version.
//
//            The CluTecLib library is distributed in the hope that it will be useful,
//            but WITHOUT ANY WARRANTY; without even the implied warranty of
//            MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//            GNU Lesser General Public License for more details.
//
//            You should have received a copy of the GNU Lesser General Public License
//            along with the CluTecLib library.
//            If not, see <http://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////////////////////////

#include "cuda_runtime.h"

#include "Statistics.DispDenoise.h"
#include "CluTec.Types1/Pixel.h"
#include "CluTec.Math/Conversion.h"

#include "CluTec.Cuda.Base/Kernel.ArrayCache.h"
#include "CluTec.Cuda.Base/Kernel.Debug.h"
#include "CluTec.Cuda.ImgProc/Kernel.Algo.ArraySum.h"

namespace Clu
{
	namespace Cuda
	{
		namespace Statistics
		{
			namespace DispDenoise
			{
				namespace Kernel
				{
					using namespace Clu::Cuda::Kernel;

					template<int t_iPatchWidth, int t_iPatchHeight
						, int t_iPatchCountY_Pow2
						, int t_iWarpsPerBlockX, int t_iWarpsPerBlockY>
						struct Constants
					{
						// Warps per block
						static const int WarpsPerBlockX = t_iWarpsPerBlockX;
						static const int WarpsPerBlockY = t_iWarpsPerBlockY;

						// Thread per warp
						static const int ThreadsPerWarp = 32;

						static const int ThreadsPerBlockX = WarpsPerBlockX * ThreadsPerWarp;

						// the width of a base patch has to be a full number of words
						static const int BasePatchSizeX = t_iPatchWidth;
						static const int BasePatchSizeY = t_iPatchHeight;
						static const int BasePatchElementCount = BasePatchSizeX * BasePatchSizeY;

						using AlgoSum = Clu::Cuda::Kernel::AlgoArraySum<ThreadsPerBlockX, t_iPatchCountY_Pow2,
							BasePatchSizeX, BasePatchSizeY>;

						static const int BasePatchCountX = AlgoSum::PatchCountX;
						static const int BasePatchCountY = AlgoSum::PatchCountY;

						static const int TestBlockSizeX = AlgoSum::DataArraySizeX + 1;
						static const int TestBlockSizeY = AlgoSum::DataArraySizeY;

						static const int SumCacheSizeX = AlgoSum::SumCacheSizeX;
						static const int SumCacheSizeY = AlgoSum::SumCacheSizeY;

						static const int ResultCountPerThread = AlgoSum::ColGroupSizeX;


#define PRINT(theVar) printf(#theVar ": %d\n", theVar)

						__device__ static void PrintValues()
						{
							printf("Block Idx: %d, %d\n", blockIdx.x, blockIdx.y);
							PRINT(ThreadsPerBlockX);
							PRINT(BasePatchSizeX);
							PRINT(BasePatchSizeY);
							PRINT(BasePatchCountX);
							PRINT(BasePatchCountY);
							PRINT(TestBlockSizeX);
							PRINT(TestBlockSizeY);
							PRINT(ResultCountPerThread);
							//PRINT();
							printf("\n");

							__syncthreads();
						}
#undef PRINT
					};

					////////////////////////////////////////////////////////////////////////////////////////////////////
					/// <summary>	The algorithm parameters. </summary>
					///
					/// <value>	. </value>
					////////////////////////////////////////////////////////////////////////////////////////////////////

					__constant__ _SParameter c_xPars;



					////////////////////////////////////////////////////////////////////////////////////////////////////
					/// <summary>	Filter with no border. </summary>
					///
					/// <typeparam name="TPixel">   	Type of the pixel. </typeparam>
					/// <typeparam name="t_eConfig">	Type of the configuration. </typeparam>
					/// <param name="xImageTrg">	The image trg. </param>
					/// <param name="xImageSrc">	The image source. </param>
					////////////////////////////////////////////////////////////////////////////////////////////////////

					template<EConfig t_eConfig>
					__global__ void FilterNoBorder(Clu::Cuda::_CDeviceSurface xImageTrg, Clu::Cuda::_CDeviceSurface xImageSrc)
					{
						using Config = SConfig<t_eConfig>;
						using Const = Kernel::Constants<Config::PatchSizeX, Config::PatchSizeY, Config::PatchCountY_Pow2, Config::WarpsPerBlockX, Config::WarpsPerBlockY>;

						using TElement = typename Clu::Cuda::SPixelTypeInfo<CDriver::TPixelDispEx>::TElement;

						using AlgoSum = typename Const::AlgoSum;
						using TDisp = typename CDriver::TPixelDisp::TData;
						using TSum = int;
						using TProd = int;

						// ////////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////

						// Get position of thread in left image
						const int iCtrX = blockIdx.x * Const::BasePatchCountX;
						const int iCtrY = blockIdx.y * Const::BasePatchCountY;

						const int iW = xImageSrc.Format().iWidth;
						const int iH = xImageSrc.Format().iHeight;

						int iPatchX = iCtrX - Const::BasePatchSizeX / 2;
						int iPatchY = iCtrY - Const::BasePatchSizeY / 2;

						// ////////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						//Debug::Run([]()
						//{
						//	if (Debug::IsThreadAndBlock(0, 0, 0, 0))
						//	{
						//		Const::PrintValues();
						//	}
						//});

						//if (!Debug::IsBlock(52, 20) && !Debug::IsBlock(53, 20))
						//{
						//	return;
						//}

						//if (Debug::IsThread(0, 0))
						//{
						//	printf("Block: %d, %d\nImage Size: %d, %d\nCenter: %d, %d\nPatch: %d, %d\n", iBlockX, iBlockY, iW, iH, iCtrX, iCtrY, iPatchX, iPatchY);
						//}
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						__shared__ Clu::Cuda::Kernel::CArrayCache<TElement
							, Const::TestBlockSizeX, Const::TestBlockSizeY
							, Const::WarpsPerBlockX, Const::WarpsPerBlockY, 8, 1>
							xCachePatch;


						__shared__ Clu::Cuda::Kernel::CArrayCache<TSum
							, Const::SumCacheSizeX, Const::SumCacheSizeY
							, Const::WarpsPerBlockX, Const::WarpsPerBlockY, 8, 1>
							xCacheSumY;


						// //////////////////////////////////////////////////////////////////////////////////////////////
						// ////////////////////////////////////////////////////////////////////////////////////////////////
						int iOffsetX, iOffsetY;
						iOffsetX = min(iPatchX, max(0, iPatchX + Const::TestBlockSizeX - iW));
						iOffsetY = min(iPatchY, max(0, iPatchY + Const::TestBlockSizeY - iH));

						if (xImageSrc.IsRectInside(iPatchX - iOffsetX, iPatchY - iOffsetY, Const::TestBlockSizeX, Const::TestBlockSizeY))
						{
							xCachePatch.ReadFromSurf<Const::TestBlockSizeX, Const::TestBlockSizeY>(xImageSrc, iPatchX - iOffsetX, iPatchY - iOffsetY);
						}
						__syncthreads();


						// //////////////////////////////////////////////////////////////////////////////////////////////
						// //////////////////////////////////////////////////////////////////////////////////////////////
						TSum piCount[Const::ResultCountPerThread];
						TSum piSum2[Const::ResultCountPerThread];

						// //////////////////////////////////////////////////////////////////////////////////////////////
						// //////////////////////////////////////////////////////////////////////////////////////////////
						Const::AlgoSum::SumCache(xCacheSumY,
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&xCachePatch, &iPatchX, &iPatchY, &iOffsetX, &iOffsetY, &iW, &iH](int iIdxX, int iIdxY)
						{
							int iX = iPatchX + iIdxX;
							int iY = iPatchY + iIdxY;

							iX += int(iX < 0) * Const::BasePatchSizeX;
							iY += int(iY < 0) * Const::BasePatchSizeY;
							iX -= int(iX >= iW) * Const::BasePatchSizeX;
							iY -= int(iY >= iH) * Const::BasePatchSizeY;

							if (iX < iW && iY < iH)
							{
								TDisp uDisp = TDisp(xCachePatch.At(iX - iPatchX + iOffsetX, iY - iPatchY + iOffsetY).x);
								return TSum((uDisp >= TDisp(EDisparityId::First)) && (uDisp <= TDisp(EDisparityId::Last)));
							}
							else
							{
								return TSum(0);
							}
						},
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&piCount, &xImageSrc, &iCtrX, &iCtrY, &iW, &iH](TSum& iValue, int iResultIdx, int iIdxX, int iIdxY)
						{
							const int iX = iCtrX + iIdxX + iResultIdx;
							const int iY = iCtrY + iIdxY;

							if (iX < iW && iY < iH)
							{
								piCount[iResultIdx] = iValue;
							}
							else
							{
								piCount[iResultIdx] = TSum(0);
							}
						});
						__syncthreads();

						// //////////////////////////////////////////////////////////////////////////////////////////////
						// //////////////////////////////////////////////////////////////////////////////////////////////
						Const::AlgoSum::SumCache(xCacheSumY,
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&xCachePatch, &iPatchX, &iPatchY, &iOffsetX, &iOffsetY, &iW, &iH](int iIdxX, int iIdxY)
						{
							int iX = iPatchX + iIdxX;
							int iY = iPatchY + iIdxY;

							iX += int(iX < 0) * Const::BasePatchSizeX;
							iY += int(iY < 0) * Const::BasePatchSizeY;
							iX -= int(iX >= iW) * Const::BasePatchSizeX;
							iY -= int(iY >= iH) * Const::BasePatchSizeY;

							if (iX < iW && iY < iH)
							{
								TDisp uDisp = TDisp(xCachePatch.At(iX - iPatchX + iOffsetX, iY - iPatchY + iOffsetY).x);
								return TSum(uDisp) * TSum(uDisp) * TSum((uDisp >= TDisp(EDisparityId::First)) && (uDisp <= TDisp(EDisparityId::Last)));
							}
							else
							{
								return TSum(0);
							}
						},
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&piSum2, &xImageSrc, &iCtrX, &iCtrY, &iW, &iH](TSum& iValue, int iResultIdx, int iIdxX, int iIdxY)
						{
							const int iX = iCtrX + iIdxX + iResultIdx;
							const int iY = iCtrY + iIdxY;

							if (iX < iW && iY < iH)
							{
								piSum2[iResultIdx] = iValue;
							}
							else
							{
								piSum2[iResultIdx] = TSum(0);
							}
						});
						__syncthreads();

						// //////////////////////////////////////////////////////////////////////////////////////////////
						// //////////////////////////////////////////////////////////////////////////////////////////////

						Const::AlgoSum::SumCache(xCacheSumY,
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&xCachePatch, &iPatchX, &iPatchY, &iOffsetX, &iOffsetY, &iW, &iH](int iIdxX, int iIdxY)
						{
							int iX = iPatchX + iIdxX;
							int iY = iPatchY + iIdxY;

							iX += int(iX < 0) * Const::BasePatchSizeX;
							iY += int(iY < 0) * Const::BasePatchSizeY;
							iX -= int(iX >= iW) * Const::BasePatchSizeX;
							iY -= int(iY >= iH) * Const::BasePatchSizeY;

							if (iX < iW && iY < iH)
							{
								TDisp uDisp = TDisp(xCachePatch.At(iX - iPatchX + iOffsetX, iY - iPatchY + iOffsetY).x);
								return TSum(uDisp) * TSum((uDisp >= TDisp(EDisparityId::First)) && (uDisp <= TDisp(EDisparityId::Last)));
							}
							else
							{
								return TSum(0);
							}
						},
							// //////////////////////////////////////////////////////////////////////////////////////////////
							[&](TSum& iValue, int iResultIdx, int iIdxX, int iIdxY)
						{
							const int iX = iCtrX + iIdxX + iResultIdx;
							const int iY = iCtrY + iIdxY;

							if (iX >= iW || iY >= iH)
							{
								return;
							}

							TDisp uDisp = TDisp(xCachePatch.At(iX - iPatchX + iOffsetX, iY - iPatchY + iOffsetY).x);
							TDisp uHasEnv = TDisp(float(piCount[iResultIdx]) >= float(Const::BasePatchElementCount) * c_xPars.fSupportRatio);

							uDisp = uHasEnv * uDisp + (1 - uHasEnv) * TDisp(EDisparityId::Unknown);

							//if (uDisp >= TDisp(EDisparityId::First) && uDisp <= TDisp(EDisparityId::Last))
							if (uHasEnv)
							{
								TDisp uIsValid = (uDisp >= TDisp(EDisparityId::First) && uDisp <= TDisp(EDisparityId::Last));
								if (uIsValid)
								{
									const float fDisp = float(uDisp);
									const float fMean = (float(iValue) - fDisp) / float(piCount[iResultIdx] - 1);
									const float fMean2 = (float(piSum2[iResultIdx]) - fDisp*fDisp) / float(piCount[iResultIdx] - 1);
									const float fStdDev = sqrtf(abs(fMean2 - fMean * fMean));

									//const TDisp uUseMean = TDisp((fStdDev < c_xPars.fMeanCutOff) && (uIsValid || c_xPars.iDoFill));
									const TDisp uUseMean = TDisp(abs(fDisp - fMean) < c_xPars.fMeanCutOff);
									const TDisp uDispMean = TDisp(floor(fMean + 0.5f));

									uDisp = uUseMean * uDispMean + (1 - uUseMean) * TDisp(EDisparityId::Unknown);
								}
								else if (c_xPars.iDoFill)
								{
									const float fMean = (float(iValue)) / float(piCount[iResultIdx]);
									const float fMean2 = (float(piSum2[iResultIdx])) / float(piCount[iResultIdx]);
									const float fStdDev = sqrtf(abs(fMean2 - fMean * fMean));

									const TDisp uUseMean = TDisp(fStdDev < c_xPars.fMeanCutOff);
									const TDisp uDispMean = TDisp(floor(fMean + 0.5f));

									uDisp = uUseMean * uDispMean + (1 - uUseMean) * uDisp;
								}
							}

							xImageTrg.Write2D<TDisp>(uDisp, iX, iY);
						});

					}

				}

				template<EConfig t_eConfig>
				void CDriver::_DoConfigure(const Clu::Cuda::CDevice& xDevice, const Clu::SImageFormat& xFormat)
				{
					using Config = SConfig<t_eConfig>;
					using Const = Kernel::Constants<Config::PatchSizeX, Config::PatchSizeY, Config::PatchCountY_Pow2, Config::WarpsPerBlockX, Config::WarpsPerBlockY>;

					unsigned nOffsetLeft = 0; //Config::PatchSizeX / 2;
					unsigned nOffsetRight = 0; //Config::PatchSizeX / 2;
					unsigned nOffsetTop = 0; //Config::PatchSizeY / 2;
					unsigned nOffsetBottom = 0; //Config::PatchSizeY / 2;

					EvalThreadConfigBlockSize(xDevice, xFormat
						, Const::BasePatchCountX, Const::BasePatchCountY
						, nOffsetLeft, nOffsetRight, nOffsetTop, nOffsetBottom
						, Config::WarpsPerBlockX, Config::WarpsPerBlockY
						, Config::NumberOfRegisters
						, false // do process partial blocks
					);
				}

				////////////////////////////////////////////////////////////////////////////////////////////////////
				/// <summary>	Configures. </summary>
				///
				/// <param name="xConfig">	[in,out] The configuration. </param>
				/// <param name="xDevice">	The device. </param>
				/// <param name="xFormat">	Describes the format to use. </param>
				////////////////////////////////////////////////////////////////////////////////////////////////////

#define _CLU_DO_CONFIG(theId) \
			case theId: \
				_DoConfigure<theId>(xDevice, xFormat); \
				break

				void CDriver::Configure(const Clu::Cuda::CDevice& xDevice, const Clu::SImageFormat& xFormat,
					const SParameter& xPars)
				{
					m_xPars = xPars;

					switch (m_xPars.eConfig)
					{
						_CLU_DO_CONFIG(EConfig::Patch_16x16);
						_CLU_DO_CONFIG(EConfig::Patch_11x11);
						_CLU_DO_CONFIG(EConfig::Patch_9x9);
						_CLU_DO_CONFIG(EConfig::Patch_7x7);
						_CLU_DO_CONFIG(EConfig::Patch_5x5);
						_CLU_DO_CONFIG(EConfig::Patch_3x3);

					default:
						throw CLU_EXCEPTION("Invalid algorithm configuration.");
					}

				}
#undef _CLU_DO_CONFIG

#define _CLU_DO_PROCESS(theId) \
			case theId: \
				Kernel::FilterNoBorder<theId> \
					CLU_KERNEL_CONFIG() \
					(xImageOut, xImageIn); \
				break

				void CDriver::_DoProcess(Clu::Cuda::_CDeviceSurface& xImageOut
					, const Clu::Cuda::_CDeviceSurface& xImageIn)
				{
					switch (m_xPars.eConfig)
					{
						_CLU_DO_PROCESS(EConfig::Patch_16x16);
						_CLU_DO_PROCESS(EConfig::Patch_11x11);
						_CLU_DO_PROCESS(EConfig::Patch_9x9);
						_CLU_DO_PROCESS(EConfig::Patch_7x7);
						_CLU_DO_PROCESS(EConfig::Patch_5x5);
						_CLU_DO_PROCESS(EConfig::Patch_3x3);

					default:
						throw CLU_EXCEPTION("Invalid algorithm configuration.");
					}

				}
#undef _CLU_DO_PROCESS

				////////////////////////////////////////////////////////////////////////////////////////////////////
				/// <summary>	Process this object. </summary>
				///
				/// <param name="dimBlocksInGrid">   	The dim blocks in grid. </param>
				/// <param name="dimThreadsPerBlock">	The dim threads per block. </param>
				/// <param name="xImageDisp">		 	[in,out] The image disp. </param>
				/// <param name="xImageL">			 	The image l. </param>
				/// <param name="xImageR">			 	The image r. </param>
				/// <param name="iOffset">			 	Zero-based index of the offset. </param>
				/// <param name="iDispRange">		 	Zero-based index of the disp range. </param>
				/// <param name="fSadThresh">		 	The sad thresh. </param>
				/// <param name="iMinDeltaThresh">   	Zero-based index of the minimum delta thresh. </param>
				////////////////////////////////////////////////////////////////////////////////////////////////////

				void CDriver::Process(Clu::Cuda::_CDeviceSurface& xImageOut
					, const Clu::Cuda::_CDeviceSurface& xImageIn)
				{
					Clu::Cuda::MemCpyToSymbol(Kernel::c_xPars, &m_xPars, 1, 0, Clu::Cuda::ECopyType::HostToDevice);

					if (!xImageOut.IsEqualSize(xImageIn.Format()))
					{
						throw CLU_EXCEPTION("Given output image has different size than input image");
					}

					if (xImageIn.IsOfType<TPixelDispEx>()
						&& xImageOut.IsOfType<TPixelDisp>())
					{
						_DoProcess(xImageOut, xImageIn);
					}
					else
					{
						throw CLU_EXCEPTION("Pixel types of given images not supported");
					}
				}

			} // Mean
		} // Statistics
	} // Cuda
} // Clu

